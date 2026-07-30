@preconcurrency import AVFoundation
import Foundation

/// Records the mic to AAC-in-CAF via AVAudioEngine. CAF on purpose: no
/// finalization pass, so a crash mid-recording loses nothing written.
/// iOS has no system-audio tap, so quill-ios records one mic track.
final class MicRecorder: @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case permissionDenied
        case engineStartFailed(Error)
        case fileCreationFailed(Error)
        case formatUnsupported

        var description: String {
            switch self {
            case .permissionDenied: return "microphone permission denied"
            case .engineStartFailed(let e): return "mic engine start failed: \(e)"
            case .fileCreationFailed(let e): return "mic file creation failed: \(e)"
            case .formatUnsupported: return "unsupported mic format"
            }
        }
    }

    private var engine = AVAudioEngine()
    private var file: AVAudioFile?
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var firstBufferAt: Date?

    /// Peak of the last tapped buffer, 0…1 — drives the live waveform.
    var currentLevel: Float { levelLock.withLock { _currentLevel } }
    private var _currentLevel: Float = 0
    private let levelLock = NSLock()
    private func setLevel(_ v: Float) { levelLock.withLock { _currentLevel = v } }

    /// Consecutive failed buffer writes. Read from the main thread, written
    /// from the audio tap, so it shares the level's lock.
    /// A handful of buffers is ~0.5s of audio — enough to distinguish a
    /// one-off hiccup from a disk that has stopped accepting writes.
    static let writeFailureLimit = 8
    var isFailingToWrite: Bool {
        levelLock.withLock { _writeFailures >= Self.writeFailureLimit }
    }
    private var _writeFailures = 0
    private var writeFailures: Int {
        get { levelLock.withLock { _writeFailures } }
        set { levelLock.withLock { _writeFailures = newValue } }
    }

    static func requestPermission() async -> Bool {
        #if DEBUG
        selfCheck()
        #endif
        return await AVAudioApplication.requestRecordPermission()
    }

    #if DEBUG
    /// The write-failure threshold: a hiccup must stay quiet, a dead disk
    /// must speak up. Both directions matter — a false alarm mid-meeting is
    /// as bad as silence.
    static func selfCheck() {
        func failing(_ n: Int) -> Bool { n >= writeFailureLimit }
        assert(!failing(0))
        assert(!failing(writeFailureLimit - 1))  // transient — stay quiet
        assert(failing(writeFailureLimit))       // real fault — speak up
        assert(failing(500))
    }
    #endif

    func start(writingTo url: URL) throws {
        guard !isRecording else { return }

        let session = AVAudioSession.sharedInstance()
        // .playAndRecord + measurement keeps the raw voice; allow bluetooth
        // mics. Background recording works via the audio background mode.
        try session.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.allowBluetooth, .defaultToSpeaker]
        )
        try session.setActive(true)

        engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: monoFormat) else {
            throw RecorderError.formatUnsupported
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        do {
            file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: monoFormat.commonFormat,
                interleaved: monoFormat.isInterleaved
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self, let file = self.file else { return }
            if self.firstBufferAt == nil { self.firstBufferAt = Date() }
            guard let mono = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: buffer.frameCapacity
            ) else { return }
            do {
                try converter.convert(to: mono, from: buffer)
                var peak: Float = 0
                if let data = mono.floatChannelData?[0] {
                    for i in 0..<Int(mono.frameLength) { peak = max(peak, abs(data[i])) }
                }
                try file.write(from: mono)
                // Level only after a successful write: it drives the live
                // waveform, and a breathing waveform over a failing write
                // (disk full) tells the user their meeting is being recorded
                // when nothing is landing.
                self.setLevel(peak)
                self.writeFailures = 0
            } catch {
                // One bad buffer shouldn't end the session; keep tapping. A
                // run of them is a real fault (out of space) — surface it.
                self.setLevel(0)
                self.writeFailures += 1
            }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            file = nil
            throw RecorderError.engineStartFailed(error)
        }
        isRecording = true
    }

    /// Pause capture without finalizing the file — the engine stops pulling
    /// buffers, the CAF stays open, resume() continues appending seamlessly.
    func pause() {
        guard isRecording, !isPaused else { return }
        engine.pause()
        isPaused = true
        setLevel(0)
    }

    func resume() throws {
        guard isRecording, isPaused else { return }
        try engine.start()
        isPaused = false
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false
        isPaused = false
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        file = nil
        setLevel(0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
