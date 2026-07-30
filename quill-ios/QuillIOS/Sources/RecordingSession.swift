import Foundation

/// One recording: a timestamped folder in Documents holding mic.caf plus
/// meta.json written on stop. Documents is exposed to the Files app
/// (UIFileSharingEnabled), so sessions are folders the user owns — same
/// contract as quill on macOS.
///
/// Two kinds: "quick" (one-tap take, folder created at record start) and
/// "note" (folder created first, recording starts inside it and can
/// pause/resume).
final class RecordingSession {
    let dir: URL
    let kind: String
    let startedAt = Date()

    private let mic = MicRecorder()
    /// Accumulated pause time, so elapsed reflects captured audio, not wall
    /// clock.
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?

    var micLevel: Float { mic.currentLevel }
    var isPaused: Bool { mic.isPaused }

    /// Recording time excluding pauses.
    var elapsed: TimeInterval {
        let pausedSoFar = pausedTotal + (pausedAt.map { Date().timeIntervalSince($0) } ?? 0)
        return Date().timeIntervalSince(startedAt) - pausedSoFar
    }

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Quick take: create a fresh timestamped folder under `root`.
    init(root: URL) throws {
        let base = Self.folderFormat.string(from: startedAt)
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
        kind = "quick"
    }

    /// Note: record into an already-created note folder.
    init(noteDir: URL) {
        dir = noteDir
        kind = "note"
    }

    /// Create an empty note folder (meta stub so it shows in the list before
    /// any audio exists).
    static func createNote(root: URL) throws -> URL {
        let base = folderFormat.string(from: Date())
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let meta: [String: Any] = [
            "kind": "note",
            "started": ISO8601DateFormatter().string(from: Date()),
            "files": [String: String](),
        ]
        let data = try JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: candidate.appendingPathComponent("meta.json"))
        return candidate
    }

    func start() throws {
        try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
        // Stub meta immediately: everything downstream (the session list and
        // the transcription queue) keys off meta.json, so a take killed or
        // jetsammed before stop() used to leave audio that never appeared and
        // never transcribed. stop() overwrites this with the final numbers.
        writeMeta(ended: nil)
    }

    func pause() {
        guard pausedAt == nil else { return }
        mic.pause()
        pausedAt = Date()
    }

    func resume() throws {
        guard let since = pausedAt else { return }
        try mic.resume()
        pausedTotal += Date().timeIntervalSince(since)
        pausedAt = nil
    }

    func stop() {
        if let since = pausedAt {
            pausedTotal += Date().timeIntervalSince(since)
            pausedAt = nil
        }
        mic.stop()
        writeMeta(ended: Date())
    }

    /// Write meta.json. `ended: nil` is the in-progress stub written at
    /// start; stop() rewrites it with the final duration.
    private func writeMeta(ended: Date?) {
        let iso = ISO8601DateFormatter()
        SessionMeta.patch(in: dir) { meta in
            meta["kind"] = kind
            meta["started"] = iso.string(from: startedAt)
            meta["files"] = ["mic": "mic.caf"]
            meta["start_offset_ms"] = ["mic": 0]
            if let ended {
                meta["ended"] = iso.string(from: ended)
                meta["duration_seconds"] = Int(elapsed)
            }
        }
    }
}

/// meta.json is the one mutable per-session record, written by several
/// unrelated passes (recording, the title from enhance, transcription
/// failures). They all need read-merge-write so none clobbers another's
/// keys, and `.atomic` so a crash mid-write can't truncate the file that
/// every downstream reader keys off.
enum SessionMeta {
    static func read(in dir: URL) -> [String: Any] {
        (try? Data(contentsOf: dir.appendingPathComponent("meta.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ?? [:]
    }

    static func patch(in dir: URL, _ mutate: (inout [String: Any]) -> Void) {
        var meta = read(in: dir)
        #if DEBUG
        let titleBefore = meta["title"] as? String
        #endif
        mutate(&meta)
        #if DEBUG
        // Every pass merges into the same file; dropping a key another pass
        // owns (the generated title is the one users would notice) is the
        // failure mode this helper exists to prevent.
        assert(
            titleBefore == nil || meta["title"] as? String == titleBefore,
            "SessionMeta.patch dropped an existing title"
        )
        #endif
        guard let data = try? JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
    }
}
