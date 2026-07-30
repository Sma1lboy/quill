import AVFoundation
import Foundation
@preconcurrency import WhisperKit

/// Serial transcription queue over WhisperKit (OpenAI Whisper, Core ML) —
/// ~100 languages including Chinese, fully on-device, auto language
/// detection. The filesystem is the queue: a session is pending iff
/// meta.json + mic.caf exist and transcript.json doesn't, so crashes just
/// retry on next launch.
actor Transcriber {
    enum Status: Sendable, Equatable {
        case idle
        /// First-run model download, fraction 0…1.
        case downloadingModel(progress: Double)
        /// progress 0…1 through the session's audio (slice checkpoints).
        case transcribing(session: String, queued: Int, progress: Double)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var pipe: WhisperKit?
    private var pipeModelID: String?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Auto-retry ceiling. A session that failed this many times is not
    /// queued at launch any more — the failure is usually deterministic (a
    /// corrupt model, an unreadable CAF), and re-loading a multi-gigabyte
    /// model on every launch forever costs the user battery and bandwidth to
    /// produce the same error. `enqueue` ignores the cap, so the manual retry
    /// path always works.
    static let maxAutoAttempts = 3

    /// Failed automatic attempts recorded in meta.json.
    static func failedAttempts(in dir: URL) -> Int {
        SessionMeta.read(in: dir)["transcribe_failures"] as? Int ?? 0
    }

    /// Only touches meta.json when there's actually a count to clear — a
    /// blind patch would create a `{}` meta in a folder that has none.
    private static func clearFailures(in dir: URL) {
        guard failedAttempts(in: dir) > 0 else { return }
        SessionMeta.patch(in: dir) { $0.removeValue(forKey: "transcribe_failures") }
    }

    func enqueue(_ sessionDir: URL) {
        // A note stopped with zero captured audio has nothing to transcribe.
        guard FileManager.default.fileExists(
            atPath: sessionDir.appendingPathComponent("mic.caf").path
        ) else { return }
        guard !Self.isMultiTrack(sessionDir) else { return }
        guard !queue.contains(sessionDir) else { return }
        // An explicit enqueue is a user action (stop, or the retry button):
        // clear the counter so a session that failed twice and is retried by
        // hand gets a full set of automatic attempts again.
        Self.clearFailures(in: sessionDir)
        queue.append(sessionDir)
        drainIfIdle()
    }

    func resumePending(root: URL) {
        #if DEBUG
        Self.selfCheckTracks()
        #endif
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }
        // Audio is the only requirement: a take killed (or jetsammed) before
        // stop() has mic.caf but no meta.json, and demanding meta.json here
        // meant that recording was never transcribed at all.
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("mic.caf").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
                    && Self.failedAttempts(in: $0) < Self.maxAutoAttempts
                    && !Self.isMultiTrack($0)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
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
            statusHandler?(.transcribing(session: dir.lastPathComponent, queued: queue.count, progress: 0))
            do {
                try await transcribe(dir)
                // Whisper (up to ~2GB resident for turbo) and any LLM must
                // never be loaded together — the pair jetsams the app.
                // Release whisper first; it reloads lazily for the next
                // queue item.
                pipe = nil
                pipeModelID = nil
                // Succeeded — drop any failure count from earlier attempts so
                // the session doesn't carry a stale marker.
                Self.clearFailures(in: dir)
                await enhanceWithFallback(dir)
                let hasNotes = FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("notes.md").path
                )
                Notify.transcriptReady(session: dir.lastPathComponent, hasNotes: hasNotes)
            } catch {
                lastFailure = dir.lastPathComponent
                let attempts = Self.failedAttempts(in: dir) + 1
                SessionMeta.patch(in: dir) { $0["transcribe_failures"] = attempts }
                log(dir, "transcription failed (attempt \(attempts)/\(Self.maxAutoAttempts)): \(error)")
                if attempts >= Self.maxAutoAttempts {
                    log(dir, "giving up automatically — use retry in the session screen")
                }
            }
        }
        // Release model memory when the queue drains; reload lazily.
        pipe = nil
        statusHandler?(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        drainIfIdle()
    }

    /// Slice length adapts to the file: aim for ~8 progress steps, floored
    /// at 15s (whisper needs real context) and capped at 120s (memory bound
    /// — the 20-min single-shot decode is what kept getting jetsammed).
    /// A 2-min take gets 15s slices (8 ticks); an hour gets 120s ones.
    /// Each slice checkpoints to partial.json, so a kill mid-file resumes
    /// from the last finished slice.
    private static func sliceSeconds(total: Double) -> Double {
        min(120, max(15, total / 8))
    }

    /// A session the macOS sibling recorded from two sources (mic + system
    /// audio, speakers "me"/"them"). iOS records one track and its whole
    /// transcribe path — language detect, slicing, the single `doneSeconds`
    /// checkpoint — assumes one file, so transcribing this here would emit
    /// the mic half only *and* write transcript.json, which is exactly what
    /// stops the Mac from ever doing it properly. Leave it for the Mac.
    ///
    /// Only reachable once sessions are shared between devices (iCloud/Files);
    /// nothing iOS records ever has a "system" track.
    ///
    /// ponytail: skip, not merge — multi-track on iOS needs per-track
    /// checkpointing, and the Mac already does this correctly.
    static func isMultiTrack(_ dir: URL) -> Bool {
        isMultiTrack(files: SessionMeta.read(in: dir)["files"] as? [String: String])
    }

    static func isMultiTrack(files: [String: String]?) -> Bool {
        files?["system"] != nil
    }

    #if DEBUG
    /// A mis-read here silently drops half a synced meeting's transcript, and
    /// the symptom (a one-sided transcript) looks like bad audio.
    static func selfCheckTracks() {
        assert(isMultiTrack(files: ["mic": "mic.caf", "system": "system.caf"]))
        assert(!isMultiTrack(files: ["mic": "mic.caf"]))   // every iOS session
        assert(!isMultiTrack(files: [:]))                  // empty note folder
        assert(!isMultiTrack(files: nil))                  // no meta.json yet
    }
    #endif

    private func transcribe(_ dir: URL) async throws {
        let audio = dir.appendingPathComponent("mic.caf")
        let probe = try AVAudioFile(forReading: audio)
        guard probe.length > 0 else {
            throw NSError(domain: "quill", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "empty audio track",
            ])
        }
        let totalSeconds = Double(probe.length) / probe.fileFormat.sampleRate

        let pipe = try await preparedPipe(logDir: dir)

        // Two-pass: detect the language first, then transcribe with an
        // explicit language prefill. Detection without prefill sometimes
        // slips into translate mode (Spanish came out as English) — pinning
        // the language token forces true transcription.
        //
        // The user picks an allowed set (mixed-language habits): one
        // selection forces it; several restrict detection's argmax to the
        // set; empty (auto) is unrestricted. zh-Hans/zh-Hant are one "zh"
        // to whisper — script is normalized after the fact.
        let selected = UserDefaults.standard.string(forKey: "quill.languages")
            .map { $0.split(separator: ",").map(String.init) } ?? []
        let allowed = Set(selected.map { $0.hasPrefix("zh") ? "zh" : $0 })

        var language: String?
        if allowed.count == 1 {
            language = allowed.first
            log(dir, "language: \(language!) (forced)")
        } else if let detection = try? await pipe.detectLanguage(audioPath: audio.path) {
            if allowed.isEmpty {
                language = detection.language
            } else {
                language = detection.langProbs
                    .filter { allowed.contains($0.key) }
                    .max { $0.value < $1.value }?.key
                    ?? detection.language
            }
            log(dir, "language: \(language ?? "?") (detected, allowed: \(allowed.sorted()))")
        }

        // Whisper's single "zh" token emits Simplified or Traditional at
        // random — normalize to the user's chosen script (default Hans).
        let zhTransform: StringTransform? = language == "zh"
            ? (selected.contains("zh-Hant")
                ? StringTransform("Hans-Hant")
                : StringTransform("Hant-Hans"))
            : nil

        // Dynamic worker count within each slice (per-worker KV caches
        // stack on the loaded weights; unbounded parallelism jetsammed
        // the app on long files).
        let workers = Self.decodeWorkerBudget()
        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: language != nil,
            detectLanguage: language == nil,
            wordTimestamps: false,
            concurrentWorkerCount: workers,
            chunkingStrategy: .vad
        )

        // Resume from checkpoint: segments for finished slices are in
        // partial.json; continue at the recorded offset.
        var checkpoint = Partial.read(from: dir) ?? Partial(doneSeconds: 0, segments: [])
        if checkpoint.doneSeconds > 0 {
            log(dir, "resuming at \(Int(checkpoint.doneSeconds))s (\(checkpoint.segments.count) segments checkpointed)")
            statusHandler?(.transcribing(
                session: dir.lastPathComponent,
                queued: queue.count,
                progress: checkpoint.doneSeconds / totalSeconds
            ))
        }
        log(dir, "decode workers: \(workers) (available: \(os_proc_available_memory() / 1_048_576) MB) · \(Int(totalSeconds))s total")

        while checkpoint.doneSeconds < totalSeconds - 0.5 {
            let sliceStart = checkpoint.doneSeconds
            let sliceEnd = min(sliceStart + Self.sliceSeconds(total: totalSeconds), totalSeconds)

            // Load just this slice (resampled to 16k by WhisperKit).
            let buffer = try AudioProcessor.loadAudio(
                fromPath: audio.path, startTime: sliceStart, endTime: sliceEnd
            )
            let samples = AudioProcessor.convertBufferToArray(buffer: buffer)
            let results = try await pipe.transcribe(audioArray: samples, decodeOptions: options)

            for result in results {
                for seg in result.segments {
                    var text = seg.text
                        .replacingOccurrences(
                            of: "<\\|[^|]*\\|>", with: "", options: .regularExpression
                        )
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    if let zhTransform {
                        text = text.applyingTransform(zhTransform, reverse: false) ?? text
                    }
                    checkpoint.segments.append(Transcript.Segment(
                        speaker: "me",
                        start_ms: Int((Double(seg.start) + sliceStart) * 1000),
                        end_ms: Int((Double(seg.end) + sliceStart) * 1000),
                        text: text
                    ))
                }
            }
            checkpoint.doneSeconds = sliceEnd
            try checkpoint.write(to: dir) // atomic — kill-safe
            log(dir, "slice done: \(Int(sliceEnd))/\(Int(totalSeconds))s")
            statusHandler?(.transcribing(
                session: dir.lastPathComponent,
                queued: queue.count,
                progress: sliceEnd / totalSeconds
            ))
        }

        var segments = checkpoint.segments
        segments.sort { $0.start_ms < $1.start_ms }

        // Speaker separation — release whisper first (diarizer models are
        // small but the decode caches aren't), then relabel by overlap.
        // Multi-voice → S1/S2/…; single voice stays "me". Best-effort.
        // (`pipe` here is the local let shadowing the actor property.)
        self.pipe = nil
        self.pipeModelID = nil
        do {
            let turns = try await Diarizer.speakerTurns(for: audio)
            if let relabeled = Diarizer.relabel(segments: segments, turns: turns) {
                segments = relabeled
                let count = Set(turns.map(\.speaker)).count
                log(dir, "diarization: \(count) speakers")
            } else {
                log(dir, "diarization: single speaker")
            }
        } catch {
            log(dir, "diarization skipped: \(error)")
        }

        let transcript = Transcript(
            engine: "whisperkit",
            model: ModelCatalog.selectedID,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: segments
        )
        try transcript.write(to: dir)
        Partial.remove(from: dir) // checkpoint no longer needed
    }

    /// Mid-transcription checkpoint: how far we got and the segments so far.
    private struct Partial: Codable {
        var doneSeconds: Double
        var segments: [Transcript.Segment]

        static func read(from dir: URL) -> Partial? {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("partial.json"))
            else { return nil }
            return try? JSONDecoder().decode(Partial.self, from: data)
        }

        func write(to dir: URL) throws {
            try JSONEncoder().encode(self)
                .write(to: dir.appendingPathComponent("partial.json"), options: .atomic)
        }

        static func remove(from dir: URL) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("partial.json"))
        }
    }

    private func preparedPipe(logDir: URL) async throws -> WhisperKit {
        let modelID = ModelCatalog.selectedID
        if let pipe, pipeModelID == modelID { return pipe }
        // Model switched in settings — drop the old one before loading.
        pipe = nil
        log(logDir, "loading \(modelID) (downloads once)")

        // On disk → load straight from the local folder, no network, no
        // download banner. (WhisperKit.download always pings the HF API to
        // re-verify the file list, which used to flash "downloading" on
        // every cold start.) Only a genuinely missing model downloads.
        let folder: URL
        if ModelCatalog.isDownloaded(modelID) {
            folder = ModelCatalog.folder(for: modelID)
        } else if let blocker = ModelCatalog.downloadBlocker(for: ModelCatalog.selected) {
            // Refuse before starting: a 3 GB download that dies at 90% burns
            // the user's cellular data and surfaces as a generic failure.
            log(logDir, "model download blocked — \(blocker)")
            throw NSError(domain: "quill", code: 2, userInfo: [
                NSLocalizedDescriptionKey: blocker,
            ])
        } else {
            let handler = statusHandler
            var lastTenth = -1
            folder = try await WhisperKit.download(
                variant: modelID,
                progressCallback: { progress in
                    let fraction = progress.fractionCompleted
                    // Progress fires very often — throttle to 10% steps.
                    let tenth = Int(fraction * 10)
                    if tenth != lastTenth {
                        lastTenth = tenth
                        handler?(.downloadingModel(progress: fraction))
                    }
                }
            )
        }

        let config = WhisperKitConfig(model: modelID, modelFolder: folder.path)
        let pipe = try await WhisperKit(config)
        self.pipe = pipe
        pipeModelID = modelID
        return pipe
    }

    /// Notes pass with fallback chain: FoundationModels (free, zero
    /// download) → local Qwen via llama.cpp (opt-in 1 GB) → give up (retry
    /// button in the session screen). Best-effort — a failure never costs
    /// the transcript.
    private func enhanceWithFallback(_ dir: URL) async {
        let notes = dir.appendingPathComponent("notes.md")
        guard !FileManager.default.fileExists(atPath: notes.path) else { return }

        let fm = FoundationModelsEnhance()
        if fm.isAvailable {
            do {
                try await fm.enhance(session: dir)
                // enhance() returns successfully without writing anything on
                // an empty transcript or an empty model response — check the
                // file rather than trusting the absence of a throw, or we log
                // a lie and skip the llama fallback.
                if FileManager.default.fileExists(atPath: notes.path) {
                    log(dir, "notes.md written (foundation-models)")
                    return
                }
                log(dir, "foundation-models produced no notes")
            } catch {
                log(dir, "foundation-models enhance failed: \(error)")
            }
        } else {
            log(dir, "foundation-models unavailable: \(FoundationModelsEnhance.unavailableReason ?? "?")")
        }

        let llama = LlamaEnhance()
        if llama.isAvailable {
            do {
                try await llama.enhance(session: dir)
                log(dir, "notes.md written (qwen-local)")
            } catch {
                log(dir, "qwen enhance failed: \(error)")
            }
        }
    }

    /// Workers = 80% of the memory still available to the process (the
    /// model weights are already resident by the time this runs), divided
    /// by a per-worker decode budget. Clamped to 1…4.
    /// ponytail: ~300 MB/worker is an empirical turbo-KV estimate; refine
    /// per-model if smaller models want more parallelism.
    private static func decodeWorkerBudget() -> Int {
        let available = Double(os_proc_available_memory())
        let perWorker = 300.0 * 1_048_576
        let budget = Int(available * 0.8 / perWorker)
        return min(4, max(1, budget))
    }

    private nonisolated func log(_ dir: URL, _ message: String) {
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
}

/// Canonical transcript, same schema as macOS quill.
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

    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // transcript.json is the queue's "done" marker (resumePending skips a
        // session once it exists), so it must be written LAST. The other way
        // round, a kill between the two writes left a session that is never
        // re-queued but has no transcript.md — and the enhance pass reads
        // transcript.md, so notes could never be produced for it.
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
    }

    static func read(from dir: URL) -> Transcript? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        else { return nil }
        return try? JSONDecoder().decode(Transcript.self, from: data)
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
