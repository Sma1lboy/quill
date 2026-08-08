import Foundation
import SwiftUI

/// One observable object owning recording, transcription, and the session
/// list. Sessions live in Documents/Recordings — visible in the Files app.
///
/// Two recording flows:
/// - Quick take: one tap on the home record bar; folder created on start.
/// - Note: create a note folder first, then record inside it with
///   pause/resume from the note screen.
@MainActor
final class AppState: ObservableObject {
    enum PipelineStatus: Equatable {
        case idle
        case downloadingModel(progress: Double)
        case transcribing(session: String, queued: Int, progress: Double)
        case failed(session: String)
    }

    let root: URL

    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    /// Folder name of the session being recorded (quick or note).
    @Published private(set) var recordingID: String?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var pipeline: PipelineStatus = .idle
    @Published private(set) var sessions: [SessionSummary] = []
    @Published var lastError: String?

    private let transcriber = Transcriber()
    /// Set synchronously when a start is requested. `isRecording` only flips
    /// after the permission `await`, so two taps inside that window both
    /// passed `guard !isRecording` and started two recorders — for a note
    /// that meant two writers truncating the same mic.caf.
    private var starting = false
    private let liveActivity = RecordingActivityController()
    private var session: RecordingSession?
    private var ticker: Timer?

    init(root: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = root ?? docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        Self.purgeTrash(root: self.root)
        // Recordings are backed up; multi-gigabyte re-downloadable weights
        // are not. Runs every launch so weights downloaded by an older build
        // get the flag too.
        ModelCatalog.excludeModelsFromBackup()
        refreshSessions()

        // Screenshot harness: QUILL_PREVIEW=recording fakes a live session
        // (no audio engine) so the recording layout renders deterministically.
        if let mode = ProcessInfo.processInfo.environment["QUILL_PREVIEW"] {
            if mode == "recording" {
                isRecording = true
                elapsed = 754
                micLevel = 0.45
            }
            sessions = SessionSummary.fakes()
            return
        }
        Task { [transcriber, root = self.root] in
            await transcriber.setStatusHandler { status in
                Task { @MainActor [weak self] in
                    self?.pipelineChanged(status)
                }
            }
            await transcriber.resumePending(root: root)
        }

        if ModelBenchmark.shouldRunOnLaunch {
            Task { [root = self.root] in
                await ModelBenchmark.run(root: root) { message in
                    Task { @MainActor [weak self] in self?.lastError = message }
                }
            }
        }
    }

    // MARK: - Quick take

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            Task { await startQuickTake() }
        }
    }

    private func startQuickTake() async {
        guard !isRecording, !starting else { return }
        starting = true
        defer { starting = false }
        guard await MicRecorder.requestPermission() else {
            lastError = "microphone permission denied — enable it in Settings"
            return
        }
        Notify.requestPermission()
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            beginTracking(newSession)
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - Notes

    /// Create an empty note folder and return its ID (nil on failure).
    func createNote() -> String? {
        do {
            let dir = try RecordingSession.createNote(root: root)
            refreshSessions()
            return dir.lastPathComponent
        } catch {
            lastError = "\(error)"
            return nil
        }
    }

    /// Bring an existing recording into a note — a voice memo, a meeting
    /// export, a video whose audio is the point. The file is transcoded into
    /// the session's `mic.caf`, so everything downstream (queue, playback,
    /// search, enhance) treats it exactly like a take made in the app.
    func importAudio(id: String, from source: URL) async throws {
        #if DEBUG
        await AudioImport.selfCheck()
        #endif
        let dir = root.appendingPathComponent(id, isDirectory: true)
        guard !isBusy(id: id), recordingID != id else {
            throw AudioImport.ImportError.sessionBusy
        }
        _ = try await AudioImport.into(dir, from: source)
        refreshSessions()
        await transcriber.enqueue(dir)
    }

    /// Start (or restart) recording inside an existing note folder.
    func startNoteRecording(id: String) {
        guard !isRecording, !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            guard await MicRecorder.requestPermission() else {
                lastError = "microphone permission denied — enable it in Settings"
                return
            }
            let newSession = RecordingSession(noteDir: root.appendingPathComponent(id, isDirectory: true))
            do {
                try newSession.start()
                beginTracking(newSession)
            } catch {
                lastError = "\(error)"
            }
        }
    }

    func pauseRecording() {
        session?.pause()
        isPaused = true
        micLevel = 0
        liveActivity.pause(elapsed: elapsed)
    }

    func resumeRecording() {
        do {
            try session?.resume()
            isPaused = false
            liveActivity.resume(elapsed: elapsed)
        } catch {
            lastError = "\(error)"
        }
    }

    func stopRecording() {
        guard let session else { return }
        session.stop()
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        isRecording = false
        isPaused = false
        recordingID = nil
        micLevel = 0
        refreshSessions()

        let dir = session.dir
        // Hand the card straight to the transcribing phase when there's audio
        // to transcribe — ending it here and re-requesting fails outright if
        // the app is backgrounded by then (Activity.request needs foreground).
        liveActivity.recordingStopped(
            willTranscribe: FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("mic.caf").path
            )
        )
        Task { [transcriber] in await transcriber.enqueue(dir) }
    }

    // MARK: -

    private func beginTracking(_ newSession: RecordingSession) {
        session = newSession
        lastError = nil
        isRecording = true
        isPaused = false
        recordingID = newSession.dir.lastPathComponent
        elapsed = 0
        liveActivity.start(kind: newSession.kind)
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    private func tick() {
        guard let session else { return }
        elapsed = session.elapsed
        micLevel = session.micLevel
        if !isPaused {
            liveActivity.level(micLevel)
        }
        // Silent audio loss is the one recording failure the user can't see —
        // the timer keeps counting either way. Say it while they can still
        // free space or stop and keep what landed.
        if session.isFailingToWrite, lastError == nil {
            lastError = "storage full — audio is no longer being saved"
        }
    }

    private func pipelineChanged(_ status: Transcriber.Status) {
        switch status {
        case .idle: pipeline = .idle
        case .downloadingModel(let p): pipeline = .downloadingModel(progress: p)
        case .transcribing(let s, let q, let p): pipeline = .transcribing(session: s, queued: q, progress: p)
        case .failed(let s): pipeline = .failed(session: s)
        }
        // Mirror pipeline state onto the Live Activity when not recording
        // (recording owns the activity while live).
        if !isRecording {
            switch status {
            case .transcribing(_, _, let p):
                liveActivity.transcribing(progress: p)
            case .idle, .failed:
                liveActivity.endTranscribing()
            case .downloadingModel:
                break // download shows in-app only
            }
        }
        refreshSessions()
    }

    func refreshSessions() {
        sessions = SessionSummary.scan(root: root)
    }

    /// Re-queue a session whose transcription gave up. `enqueue` clears the
    /// persisted failure count, so this restores the full set of automatic
    /// attempts rather than granting exactly one more.
    func retryTranscription(id: String) {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        Task { [transcriber] in
            await transcriber.enqueue(dir)
            // enqueue clears the marker; refresh so the row drops its failed
            // badge even if enqueue bailed and no status callback fires.
            refreshSessions()
        }
    }

    /// Throw the transcript away and run the whole pipeline again — for a
    /// take that came out in the wrong language, on a model since upgraded,
    /// or garbled. Audio is never touched.
    func retranscribe(id: String) {
        guard !isBusy(id: id) else { return }
        let dir = root.appendingPathComponent(id, isDirectory: true)
        Task { [transcriber] in
            if await !transcriber.retranscribe(dir) {
                lastError = "nothing to re-transcribe — this session has no audio"
            }
            refreshSessions()
        }
    }

    /// Re-run the notes pass over the existing transcript, through the same
    /// backend chain the automatic pass uses. Returns the reason it failed,
    /// or nil on success.
    ///
    /// Refuses while the queue is transcribing: whisper (up to ~2 GB
    /// resident) and an LLM must never be loaded at once — that pair is what
    /// jetsams the app, and the queue's own stages are ordered to avoid it.
    func regenerateNotes(id: String) async -> String? {
        if case .transcribing = pipeline {
            return "wait for the current transcription to finish"
        }
        let dir = root.appendingPathComponent(id, isDirectory: true)
        let reason = await transcriber.enhance(dir, force: true)
        refreshSessions()
        return reason
    }

    /// Dismiss the failure banner. `Transcriber.lastFailure` is only cleared
    /// when a new job starts, so after the last session in the queue fails the
    /// banner has nothing to clear it — it sits there until the app is killed.
    /// The row keeps its ERR tag and its retry button, so acknowledging here
    /// loses nothing: this is the notice, not the state.
    func acknowledgeFailure() {
        guard case .failed = pipeline else { return }
        pipeline = .idle
        Task { [transcriber] in await transcriber.clearLastFailure() }
    }

    /// Rename a session — stores the title in meta.json, which
    /// `SessionSummary.scan` already reads, so the home list and search rows
    /// both follow. Empty clears it back to the timestamp.
    func renameSession(id: String, to title: String) {
        FoundationModelsEnhance.saveTitle(
            title,
            in: root.appendingPathComponent(id, isDirectory: true),
            overwrite: true
        )
        refreshSessions()
    }

    /// True while this session is recording or being transcribed — deleting it
    /// would pull the folder out from under the writer.
    func isBusy(id: String) -> Bool {
        if id == recordingID { return true }
        if case .transcribing(let s, _, _) = pipeline, s == id { return true }
        return false
    }

    /// Delete a session: the folder moves into Documents/.trash instead of
    /// vanishing, so a slip is recoverable from Files. Trash older than 7 days
    /// is purged on launch. Refuses while the session is busy — the swipe row
    /// and the detail menu both gate on `isBusy` first, this is the backstop.
    func deleteSession(id: String) {
        guard !isBusy(id: id) else { return }
        let fm = FileManager.default
        let trash = root.deletingLastPathComponent()
            .appendingPathComponent(".trash", isDirectory: true)
        try? fm.createDirectory(at: trash, withIntermediateDirectories: true)
        let src = root.appendingPathComponent(id, isDirectory: true)
        let dst = trash.appendingPathComponent(id, isDirectory: true)
        try? fm.removeItem(at: dst)
        if (try? fm.moveItem(at: src, to: dst)) == nil {
            try? fm.removeItem(at: src) // move failed — fall back to delete
        }
        refreshSessions()
    }

    /// Purge trash entries older than 7 days (called once at launch).
    nonisolated static func purgeTrash(root: URL) {
        let fm = FileManager.default
        let trash = root.deletingLastPathComponent()
            .appendingPathComponent(".trash", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        for url in (try? fm.contentsOfDirectory(
            at: trash, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? [] {
            let modified = (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// One row in the session list, derived purely from disk.
struct SessionSummary: Identifiable, Equatable {
    enum Stage: Equatable {
        case empty        // note folder with no audio yet
        case recorded     // audio only
        case failed       // audio, but quill stopped retrying transcription
        case transcribed  // intermediate: transcript, no notes yet
        case noted        // final: notes.md exists
    }

    /// Stage for one folder, from the files present plus the same failure
    /// count the queue itself reads (`Transcriber.failedAttempts`) — one
    /// threshold, not a second copy that can drift from `resumePending`'s.
    ///
    /// `.failed` only shadows `.recorded`: once a transcript exists the
    /// session succeeded, and a hand-retry clears the count via `enqueue`,
    /// so the row stops reading ERR the moment the user retries.
    /// Nonisolated and disk-only, so `scan` can call it off the main actor.
    static func stage(of dir: URL, fm: FileManager = .default) -> Stage {
        if fm.fileExists(atPath: dir.appendingPathComponent("notes.md").path) { return .noted }
        if fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) { return .transcribed }
        guard fm.fileExists(atPath: dir.appendingPathComponent("mic.caf").path) else { return .empty }
        return Transcriber.failedAttempts(in: dir) >= Transcriber.maxAutoAttempts
            ? .failed
            : .recorded
    }

    let id: String
    let dir: URL
    let kind: String      // "quick" | "note"
    let started: Date?
    let duration: Int?
    let stage: Stage
    /// LLM-generated (or user-set) content title from meta.json, if any.
    let contentTitle: String?

    /// Content title when we have one; falls back to relative time.
    var title: String { contentTitle ?? timeTitle }

    var timeTitle: String {
        guard let started else { return id }
        let time = started.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(started) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(started) { return "Yesterday \(time)" }
        let day = started.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(day) · \(time)"
    }

    /// Screenshot-harness rows (QUILL_PREVIEW) — never used in normal runs.
    static func fakes() -> [SessionSummary] {
        let now = Date()
        let tmp = URL(fileURLWithPath: "/tmp")
        return [
            SessionSummary(id: "a", dir: tmp, kind: "note", started: now.addingTimeInterval(-3600 * 4),
                           duration: 2820, stage: .noted, contentTitle: "weekly planning · pricing"),
            SessionSummary(id: "b", dir: tmp, kind: "quick", started: now.addingTimeInterval(-3600 * 26),
                           duration: 1920, stage: .transcribed, contentTitle: nil),
            SessionSummary(id: "c", dir: tmp, kind: "quick", started: now.addingTimeInterval(-3600 * 30),
                           duration: 300, stage: .recorded, contentTitle: nil),
        ]
    }

    static func scan(root: URL, limit: Int = 50) -> [SessionSummary] {
        #if DEBUG
        selfCheckStage()  // every list load and every search goes through here
        #endif
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .map { dir in
                var started: Date?
                var duration: Int?
                var kind = "quick"
                var contentTitle: String?
                if let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    duration = json["duration_seconds"] as? Int
                    kind = json["kind"] as? String ?? "quick"
                    contentTitle = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    if let s = json["started"] as? String {
                        started = ISO8601DateFormatter().date(from: s)
                    }
                }
                return SessionSummary(
                    id: dir.lastPathComponent,
                    dir: dir,
                    kind: kind,
                    started: started,
                    duration: duration,
                    stage: stage(of: dir, fm: fm),
                    contentTitle: contentTitle
                )
            }
    }

    #if DEBUG
    /// Both directions of the ERR threshold, against real folders: a session
    /// at the cap must read `.failed` (the list said "waiting" about something
    /// permanently stopped), and one below it must still read `.recorded` — a
    /// premature ERR on a session merely queued is the same lie inverted.
    static func selfCheckStage() {
        let fm = FileManager.default
        let box = fm.temporaryDirectory
            .appendingPathComponent("quill-stagecheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: box) }

        func folder(_ name: String, files: [String], failures: Int? = nil) -> URL {
            let dir = box.appendingPathComponent(name, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in files {
                try? Data("x".utf8).write(to: dir.appendingPathComponent(f))
            }
            if let failures {
                SessionMeta.patch(in: dir) { $0["transcribe_failures"] = failures }
            }
            return dir
        }

        let cap = Transcriber.maxAutoAttempts
        assert(stage(of: folder("none", files: [])) == .empty)
        assert(stage(of: folder("queued", files: ["mic.caf"])) == .recorded)
        // Below the cap it is still going to be retried — not a failure yet.
        assert(stage(of: folder("try1", files: ["mic.caf"], failures: 1)) == .recorded)
        assert(stage(of: folder("try-last", files: ["mic.caf"], failures: cap - 1)) == .recorded)
        // At and past the cap nothing will retry it automatically again.
        assert(stage(of: folder("gaveup", files: ["mic.caf"], failures: cap)) == .failed)
        assert(stage(of: folder("gaveup-more", files: ["mic.caf"], failures: cap + 5)) == .failed)
        // A hand-retry clears the count (see Transcriber.enqueue) — the row
        // has to drop ERR immediately, not wait for the next attempt.
        let retried = folder("retried", files: ["mic.caf"], failures: cap)
        assert(stage(of: retried) == .failed)
        SessionMeta.patch(in: retried) { $0.removeValue(forKey: "transcribe_failures") }
        assert(stage(of: retried) == .recorded, "a cleared count must stop reading as failed")
        // A transcript outranks stale failure counts from earlier attempts.
        assert(stage(of: folder("won", files: ["mic.caf", "transcript.json"], failures: cap)) == .transcribed)
        assert(stage(of: folder("noted", files: ["mic.caf", "transcript.json", "notes.md"], failures: cap)) == .noted)
    }
    #endif
}
