import AVFoundation
import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = you, system = them) plus a meta.json written on clean stop. Tracks
/// are separate on purpose — whisper does better on clean single-source audio,
/// and two tracks give free two-party diarization.
final class RecordingSession {
    let dir: URL
    let startedAt = Date()

    private let mic = MicRecorder()
    private let system = SystemAudioRecorder()

    /// Live mic input peak, 0…1 — feeds the popover's waveform meter.
    var micLevel: Float { mic.currentLevel }

    /// The audio route changed mid-recording, so the mic track stopped growing.
    var routeChanged: Bool { mic.routeChanged }

    /// Mic buffers are being dropped instead of written — effectively a full
    /// disk. The take is still running, but audio is being lost.
    var isFailingToWrite: Bool { mic.isFailingToWrite }

    /// Rebuild meta.json for sessions killed before `stop()` ran (SIGKILL,
    /// panic, power loss — `applicationWillTerminate` covers the graceful
    /// cases). Audio is on disk but every scan keys off meta.json, so without
    /// this the recording is invisible to the app forever. Duration comes from
    /// the file itself; offsets are lost, which only shifts one track's
    /// timestamps by tens of ms.
    /// ponytail: mic-only recovery. The system track's alignment is
    /// unknowable after the fact, and a recovered session is already a
    /// degraded case.
    static func recoverOrphans(root: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }

        for dir in entries {
            let mic = dir.appendingPathComponent("mic.caf")
            guard !fm.fileExists(atPath: dir.appendingPathComponent("meta.json").path),
                  fm.fileExists(atPath: mic.path),
                  let audio = try? AVAudioFile(forReading: mic),
                  audio.length > 0
            else { continue }

            let seconds = Int(Double(audio.length) / audio.fileFormat.sampleRate)
            let started = folderFormat.date(from: dir.lastPathComponent)
                ?? (try? fm.attributesOfItem(atPath: mic.path)[.creationDate] as? Date)
                ?? Date()
            let iso = ISO8601DateFormatter()
            let meta: [String: Any] = [
                "started": iso.string(from: started),
                "ended": iso.string(from: started.addingTimeInterval(Double(seconds))),
                "duration_seconds": seconds,
                "files": ["mic": "mic.caf"],
                "start_offset_ms": ["mic": 0],
                "recovered": true,
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]
            ) else { continue }
            try? data.write(to: dir.appendingPathComponent("meta.json"), options: .atomic)
            FileHandle.standardError.write(Data(
                "recovered \(dir.lastPathComponent) (\(seconds)s, no clean stop)\n".utf8
            ))
        }
    }

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Create the session folder under `root` (yyyy.MM.dd-HHmm, suffixed on
    /// collision) without starting capture yet.
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
    }

    /// Why the system track is missing, when it is. Surfaced by AppState so a
    /// mic-only session says so instead of looking complete.
    private(set) var systemTrackError: String?

    /// Start capture. The mic is essential — a failure there fails the session.
    /// The system tap is best-effort: denying "System Audio Recording" (or any
    /// Mac where the tap won't create) used to make recording impossible at
    /// all, so a tap failure now degrades to a mic-only session instead.
    func start() throws {
        try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
        do {
            try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        } catch {
            systemTrackError = "\(error)"
            FileHandle.standardError.write(Data(
                "warning: system audio unavailable (\(error)) — recording mic only\n".utf8
            ))
        }
    }

    /// Stop both tracks and write meta.json.
    func stop() {
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each
        // lags the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        // A track that never received a buffer isn't in `files`: the tap failed
        // to start, or started and stayed silent (nothing was playing). Listing
        // it anyway made the coordinator log a missing-track skip on every such
        // session and told the user a two-sided recording existed.
        var files = ["mic": "mic.caf"]
        var offsets = ["mic": Int(micStart.timeIntervalSince(earliest) * 1000)]
        if system.firstBufferAt != nil {
            files["system"] = "system.caf"
            offsets["system"] = Int(systemStart.timeIntervalSince(earliest) * 1000)
        }

        var meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": files,
            "start_offset_ms": offsets,
        ]
        // Recorded so a one-sided session is explainable after the fact.
        if let systemTrackError {
            meta["system_track_error"] = systemTrackError
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: meta,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }
}
