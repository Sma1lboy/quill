import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case structuring(session: String, queued: Int)
        case failed(session: String)
    }

    enum TranscribeError: Error, CustomStringConvertible {
        /// No track yielded a transcript, so there is nothing to write.
        case allTracksFailed([String])

        var description: String {
            switch self {
            case .allTracksFailed(let reasons):
                return reasons.isEmpty
                    ? "no audio tracks to transcribe"
                    : "every track failed — \(reasons.joined(separator: "; "))"
            }
        }
    }

    /// Written into a session folder when its transcription throws, so the
    /// popover can distinguish "failed" from "not started yet".
    static let failureMarker = "transcribe.failed"

    /// Auto-retry ceiling, same value and same meta.json key as the iOS
    /// sibling (`transcribe_failures`, Transcriber.maxAutoAttempts). A session
    /// that failed this many times isn't queued at launch any more: the failure
    /// is usually deterministic (a corrupt model, an unreadable CAF), and
    /// reloading the model every launch forever produces the same error. The
    /// count lives in meta.json rather than beside the marker so a session
    /// carries its attempt history between devices. `enqueue` ignores the cap,
    /// so the popover's `retry` always works.
    static let maxAutoAttempts = 3

    private var queue: [URL] = []
    /// The job `drain()` is on right now. It's already off `queue`, so without
    /// this a retry clicked mid-transcription passes the dedup check and
    /// re-queues the folder being processed — the same session transcribes
    /// twice and `claude -p` runs twice on it.
    private var inFlight: URL?
    private var draining = false
    private var engine: TranscriptionEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    /// Also the retry path: the popover re-enqueues a failed session, so the
    /// dedup guard lives here rather than at each caller (a double-clicked
    /// retry would otherwise transcribe the same folder twice).
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        guard !queue.contains(sessionDir), sessionDir != inFlight else { return }
        // An explicit enqueue is a user action (stop, or the popover's retry):
        // clear the counter so a session that hit the cap and is retried by
        // hand gets a full set of automatic attempts again, rather than one.
        SessionMeta.clearFailures(in: sessionDir)
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
                    // A folder with no audio has nothing to transcribe. iOS
                    // creates note folders on open and writes `files: {}` until
                    // a take lands; without this those queue and fail on every
                    // launch once the folders are shared with this app.
                    && ((try? SessionMeta.read(from: $0).tracks.isEmpty) == false)
                    // Deterministic failures stop costing a model load per
                    // launch once they've had their attempts (iOS parity).
                    && SessionMeta.failedAttempts(in: $0) < Self.maxAutoAttempts
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            inFlight = dir
            defer { inFlight = nil }
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            // Clear any previous attempt's marker so a retry that succeeds
            // doesn't leave the row stuck on ERR.
            try? FileManager.default.removeItem(
                at: dir.appendingPathComponent(Self.failureMarker)
            )
            do {
                try await transcribe(dir)
                // Succeeded — drop any attempt count from earlier tries so the
                // session doesn't carry a stale one to the next device.
                SessionMeta.clearFailures(in: dir)
                structureNotes(dir)
                notifyUser(title: "quill — transcript ready", body: dir.lastPathComponent)
                runHook(for: dir)
            } catch {
                let attempts = SessionMeta.recordFailure(in: dir)
                log(dir, "transcription failed (attempt \(attempts)/\(Self.maxAutoAttempts)): \(error)")
                if attempts >= Self.maxAutoAttempts {
                    log(dir, "giving up automatically — hover the row for retry")
                }
                // Marker so the popover can show ERR instead of a row that
                // looks identical to never-transcribed.
                try? Data("\(error)\n".utf8).write(
                    to: dir.appendingPathComponent(Self.failureMarker), options: .atomic
                )
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "quill — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine(logDir: dir)

        var merged: [Transcript.Segment] = []
        // A per-track failure is survivable only while some other track still
        // produced a transcript; if every track was skipped there is nothing to
        // write, and "done — 0 segments" would be indistinguishable from a
        // genuinely silent recording. Counted rather than inferred from
        // `merged.isEmpty`, because real silence is a legitimate 0-segment
        // success and must not be turned into a failure.
        var transcribed = 0
        var skips: [String] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                skips.append("\(track.file): missing")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            // One bad track (empty, truncated) shouldn't cost us the other's
            // transcript — log it and keep going.
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                skips.append("\(track.file): \(error)")
                continue
            }
            transcribed += 1
            let offset = TimeInterval(track.offsetMs) / 1000
            merged += segments.map {
                Transcript.Segment(
                    speaker: track.speaker,
                    start_ms: Int(($0.start + offset) * 1000),
                    end_ms: Int(($0.end + offset) * 1000),
                    text: $0.text
                )
            }
        }
        // Every track failed (or there were none): writing transcript.json here
        // would mark the session done forever — no retry, no ERR, no notes —
        // while reporting success. Throw so the failure marker and the attempt
        // count get written and the row reads ERR, matching iOS, which throws
        // on unreadable audio before it can reach this point
        // (Transcriber.swift:181).
        guard transcribed > 0 else {
            throw TranscribeError.allTracksFailed(skips)
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    /// LLM structuring pass — best-effort: a failure logs and notifies but
    /// never fails the session (the transcript is already on disk).
    private func structureNotes(_ dir: URL) {
        guard Config.notesEnabled() else { return }
        // Idempotent for resumed sessions that already have notes.
        guard !FileManager.default.fileExists(
            atPath: dir.appendingPathComponent("notes.md").path
        ) else { return }
        // Nothing was said: silence, a truncated file, a failed mic. Structuring
        // an empty transcript spends an LLM call to produce "Summary: none".
        guard (Transcript.read(from: dir)?.segments.isEmpty ?? true) == false else {
            log(dir, "no speech — skipping notes")
            return
        }
        publish(.structuring(session: dir.lastPathComponent, queued: queue.count))
        log(dir, "structuring notes via `\(Config.llmCommand())`")
        do {
            try NotesStructurer.structure(dir)
            log(dir, "notes.md written")
        } catch {
            log(dir, "notes structuring failed: \(error)")
            notifyUser(
                title: "quill — notes failed",
                body: "\(dir.lastPathComponent) — transcript is still there"
            )
        }
    }

    private func preparedEngine(logDir: URL) async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        if configured != "whisperkit" {
            // stderr alone is invisible under a LaunchAgent — put it where the
            // user already looks when a session comes out wrong.
            let warning = "warning: unknown transcription engine "
                + "\"\(configured)\" — using whisperkit"
            FileHandle.standardError.write(Data((warning + "\n").utf8))
            log(logDir, warning)
        }
        let engine = WhisperKitEngine(languages: Config.transcriptionLanguages())
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    /// Failed automatic attempts recorded in meta.json — the same key the iOS
    /// sibling writes, so a session's attempt history survives the trip
    /// between devices.
    static func failedAttempts(in dir: URL) -> Int {
        raw(in: dir)["transcribe_failures"] as? Int ?? 0
    }

    static func recordFailure(in dir: URL) -> Int {
        let attempts = failedAttempts(in: dir) + 1
        patch(in: dir) { $0["transcribe_failures"] = attempts }
        return attempts
    }

    /// Only touches meta.json when there's a count to clear — a blind patch
    /// would create a `{}` meta in a folder that has none.
    static func clearFailures(in dir: URL) {
        guard failedAttempts(in: dir) > 0 else { return }
        patch(in: dir) { $0.removeValue(forKey: "transcribe_failures") }
    }

    private static func raw(in dir: URL) -> [String: Any] {
        (try? Data(contentsOf: dir.appendingPathComponent("meta.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? [:]
    }

    /// Read-merge-write, mirroring iOS's `SessionMeta.patch`: several unrelated
    /// passes own keys in this one file, so no writer may clobber another's.
    /// `.atomic` because every downstream reader keys off meta.json.
    private static func patch(in dir: URL, _ mutate: (inout [String: Any]) -> Void) {
        var meta = raw(in: dir)
        guard !meta.isEmpty else { return }  // no meta.json — nothing to annotate
        mutate(&meta)
        guard let data = try? JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    static func read(from dir: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
    }

    /// Write transcript.md, then transcript.json. Both writes are atomic (temp
    /// file + rename), so a partially written file never exists on disk — but
    /// the *order* matters just as much, and it must match the iOS sibling
    /// (QuillIOS/Sources/Transcription/Transcriber.swift:470).
    ///
    /// transcript.json is the queue's done-marker: `resumePending` skips a
    /// session once it exists. Writing it first meant a kill between the two
    /// writes left a session that is never re-queued and has no transcript.md
    /// — and `NotesStructurer` reads transcript.md, so notes.md could never be
    /// produced for it. md first makes the same kill recoverable: the session
    /// stays pending and the next launch redoes both.
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
