import AppKit
import SwiftUI

@main
enum QuillAppMain {
    static func main() {
        // Writing the transcript to a structuring command that already exited
        // (`claude` not on the LaunchAgent PATH) otherwise takes quill down with
        // SIGPIPE mid-write. Ignored here so the write returns EPIPE and
        // NotesStructurer can report it as a normal failure.
        signal(SIGPIPE, SIG_IGN)

        #if DEBUG
        WhisperKitEngine.selfCheck()
        TranscriptSearch.selfCheck()
        MainActor.assumeIsolated { StatusItemController.selfCheck() }
        #endif

        let env = ProcessInfo.processInfo.environment
        let root = env["QUILL_ROOT"].map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
        } ?? Config.resolveRoot(cliOverride: nil)

        // QUILL_PREVIEW=idle|recording: open the popover content in a plain
        // window for screenshots — no status item interaction needed.
        if let mode = env["QUILL_PREVIEW"] {
            PreviewHarness.run(root: root, mode: mode)
            return
        }

        // Two instances both drain the queue: the same session gets transcribed
        // twice and `claude -p` runs twice, interleaving writes to one
        // transcript.json. An advisory lock on the recordings root is enough —
        // it's the shared resource, and the kernel drops the lock however we
        // exit (no stale-pidfile cleanup to get wrong).
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = open(root.appendingPathComponent(".quill.lock").path, O_CREAT | O_RDWR, 0o644)
        if lock < 0 || flock(lock, LOCK_EX | LOCK_NB) != 0 {
            FileHandle.standardError.write(Data(
                "quill is already running for \(root.path) — quitting\n".utf8
            ))
            return
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = AppDelegate(root: root)
        app.delegate = delegate

        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            MainActor.assumeIsolated { delegate.shutdown() }
        }
        sigint.resume()
        // Keep the source alive for the app's lifetime.
        delegate.sigintSource = sigint

        FileHandle.standardError.write(Data(
            "quill up · recordings → \(root.path) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let state: AppState
    private var statusController: StatusItemController?
    var sigintSource: DispatchSourceSignal?

    init(root: URL) {
        state = AppState(root: root)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(state: state)
    }

    /// Log out / restart / `killall` all arrive here, not through the SIGINT
    /// handler. Without this the in-progress session never got its meta.json,
    /// and both SessionSummary.scan and resumePending key off meta.json — so
    /// the audio stayed on disk and the app ignored it forever.
    func applicationWillTerminate(_ notification: Notification) {
        state.stopIfRecording()
    }

    func shutdown() {
        state.stopIfRecording()
        NSApp.terminate(nil)
    }
}

// MARK: - App state

/// One observable object owning recording, transcription, and the session
/// list. All mutation on the main actor.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(started: Date)
    }

    enum PipelineStatus: Equatable {
        case idle
        case transcribing(session: String, queued: Int)
        case structuring(session: String, queued: Int)
        case failed(session: String)
    }

    let root: URL

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var pipeline: PipelineStatus = .idle
    @Published private(set) var sessions: [SessionSummary] = []
    /// System audio unavailable for the live session — recording mic only.
    @Published private(set) var micOnly = false
    @Published var lastError: String?

    private let transcription = TranscriptionCoordinator()
    private var session: RecordingSession?
    private var ticker: Timer?

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    init(root: URL) {
        self.root = root

        // The preview harness renders fake sessions — don't try to transcribe them.
        guard ProcessInfo.processInfo.environment["QUILL_PREVIEW"] == nil else {
            refreshSessions()
            return
        }

        // Before the first scan: a session killed mid-recording has no
        // meta.json, so it's invisible to both scan and resumePending until
        // this rebuilds it.
        RecordingSession.recoverOrphans(root: root)
        refreshSessions()

        // Built outside the Task deliberately: the coordinator stores this
        // handler for the process's life, so it must hold us weakly — nested
        // inside the Task, the `weak self` sat under an implicit strong capture
        // of self in the enclosing closure (the AppState → coordinator →
        // handler → AppState cycle the compiler was warning about).
        let onStatus: @Sendable (TranscriptionCoordinator.Status) -> Void = { [weak self] status in
            Task { @MainActor in self?.pipelineChanged(status) }
        }
        Task { [transcription] in
            await transcription.setStatusHandler(onStatus)
            await transcription.resumePending(root: root)
        }
    }

    func toggleRecording() {
        isRecording ? stopIfRecording() : startRecording()
    }

    private func startRecording() {
        do {
            let newSession = try RecordingSession(root: root)
            try newSession.start()
            session = newSession
            lastError = nil
            FileHandle.standardError.write(Data("● recording → \(newSession.dir.path)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("recording start failed: \(error)\n".utf8))
            lastError = "\(error)"
            notifyUser(title: "quill — recording failed", body: "\(error)")
            return
        }

        phase = .recording(started: session!.startedAt)
        // A tap failure isn't fatal any more, so it has to be visible — the
        // header kicker would otherwise still promise both sides.
        micOnly = session?.systemTrackError != nil
        elapsed = 0
        // 1:15 s — smooth enough for a level meter without burning CPU.
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stopIfRecording() {
        guard let session else { return }
        session.stop()
        FileHandle.standardError.write(Data(
            "○ stopped · \(session.dir.path)\n".utf8
        ))
        self.session = nil
        ticker?.invalidate()
        ticker = nil
        phase = .idle
        micLevel = 0
        micOnly = false
        refreshSessions()

        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    private func tick() {
        guard let session else { return }
        elapsed = Date().timeIntervalSince(session.startedAt)
        micLevel = session.micLevel
        // A dead route means the timer is counting past the end of the audio;
        // say so instead of showing a healthy-looking recording.
        if session.routeChanged, lastError == nil {
            lastError = "audio route changed — mic capture stopped, stop and start again"
        }
    }

    private func pipelineChanged(_ status: TranscriptionCoordinator.Status) {
        switch status {
        case .idle: pipeline = .idle
        case .transcribing(let s, let q): pipeline = .transcribing(session: s, queued: q)
        case .structuring(let s, let q): pipeline = .structuring(session: s, queued: q)
        case .failed(let s): pipeline = .failed(session: s)
        }
        refreshSessions()
    }

    func refreshSessions() {
        sessions = SessionSummary.scan(root: root)
    }

    /// Re-queue a session whose transcription failed. The coordinator clears
    /// the failure marker when it picks the job up, so the row leaves ERR as
    /// soon as work starts.
    func retry(_ session: SessionSummary) {
        let dir = session.dir
        Task { [transcription] in await transcription.enqueue(dir) }
    }

    /// Preview-harness only: fake a live recording (no audio engines) so the
    /// recording layout can be screenshotted deterministically.
    func enterPreviewRecording() {
        phase = .recording(started: Date().addingTimeInterval(-754))
        elapsed = 754
        micLevel = 0.45
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    func quit() {
        stopIfRecording()
        NSApp.terminate(nil)
    }

    static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Session summaries

/// One row in the popover's session list, derived purely from what's on disk.
struct SessionSummary: Identifiable, Equatable {
    enum Stage: Equatable {
        case recorded      // audio only
        case failed        // transcription threw; transcribe.failed present
        case transcribed   // transcript.json present
        case structured    // notes.md present
    }

    let id: String        // folder name
    let dir: URL
    let started: Date?
    let duration: Int?    // seconds
    let stage: Stage

    /// Row label: relative for the last two days, else weekday + date.
    /// Shared with search hits so both lists name a session identically.
    var title: String {
        guard let started else { return id }
        let time = started.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(started) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(started) { return "Yesterday \(time)" }
        let day = started.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(day) · \(time)"
    }

    static func scan(root: URL, limit: Int = 20) -> [SessionSummary] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        return entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } // names sort chronologically
            .prefix(limit)
            .map { dir in
                var started: Date?
                var duration: Int?
                if let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    duration = json["duration_seconds"] as? Int
                    if let s = json["started"] as? String {
                        started = ISO8601DateFormatter().date(from: s)
                    }
                }
                // Order matters: a session that failed, was retried, and
                // succeeded has both marker and transcript — the artifact wins.
                let stage: Stage
                if fm.fileExists(atPath: dir.appendingPathComponent("notes.md").path) {
                    stage = .structured
                } else if fm.fileExists(atPath: dir.appendingPathComponent("transcript.json").path) {
                    stage = .transcribed
                } else if fm.fileExists(atPath: dir.appendingPathComponent(
                    TranscriptionCoordinator.failureMarker
                ).path) {
                    stage = .failed
                } else {
                    stage = .recorded
                }
                return SessionSummary(
                    id: dir.lastPathComponent,
                    dir: dir,
                    started: started,
                    duration: duration,
                    stage: stage
                )
            }
    }
}
