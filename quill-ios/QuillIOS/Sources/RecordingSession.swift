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

        let ended = Date()
        let iso = ISO8601DateFormatter()
        let meta: [String: Any] = [
            "kind": kind,
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(elapsed),
            "files": ["mic": "mic.caf"],
            "start_offset_ms": ["mic": 0],
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }
}
