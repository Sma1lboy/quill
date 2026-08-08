import AVFoundation
import Foundation

/// Bring an existing recording into a note: a voice memo, a meeting export, a
/// video whose audio is the point. The pipeline only ever reads `mic.caf`, so
/// an import is a transcode into that one file — no second code path, no
/// per-source special cases downstream.
///
/// Video is not a special case either: `AVAssetReader` over the audio track
/// ignores the picture entirely, so a 4K screen recording costs the same as
/// the equivalent m4a.
enum AudioImport {
    enum ImportError: LocalizedError {
        case noAudioTrack
        case sessionBusy
        case alreadyHasAudio
        case unreadable(Error)

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: return "no audio track in that file"
            case .sessionBusy: return "can't import while this note is recording"
            case .alreadyHasAudio: return "this note already has audio"
            case .unreadable(let e): return "couldn't read that file: \(e.localizedDescription)"
            }
        }
    }

    /// Types the picker offers. Video is included deliberately — the audio is
    /// extracted and the picture is dropped, so the user never carries a
    /// gigabyte of frames they didn't want.
    static let contentTypes: [UTType] = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]

    /// Transcode `source` into `dir/mic.caf` and write the meta the queue
    /// needs. Returns the duration written.
    ///
    /// Refuses rather than overwrites when audio already exists: mic.caf is
    /// the one file quill promises never to replace, and an import that
    /// clobbered a real take would be the worst kind of data loss.
    static func into(_ dir: URL, from source: URL) async throws -> TimeInterval {
        let dest = dir.appendingPathComponent("mic.caf")
        guard !FileManager.default.fileExists(atPath: dest.path) else {
            throw ImportError.alreadyHasAudio
        }

        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ImportError.noAudioTrack
        }

        // Write beside the destination, then move: a kill mid-transcode must
        // not leave a half file at mic.caf, which the queue would happily
        // pick up and transcribe as a truncated recording.
        let temp = dir.appendingPathComponent("mic.caf.part")
        try? FileManager.default.removeItem(at: temp)
        do {
            try await transcode(track: track, of: asset, to: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw ImportError.unreadable(error)
        }
        try FileManager.default.moveItem(at: temp, to: dest)

        let seconds = try await CMTimeGetSeconds(asset.load(.duration))
        SessionMeta.patch(in: dir) {
            $0["files"] = ["mic": "mic.caf"]
            $0["start_offset_ms"] = ["mic": 0]
            $0["duration_seconds"] = Int(seconds.isFinite ? seconds : 0)
            $0["imported"] = true
            $0["ended"] = ISO8601DateFormatter().string(from: Date())
        }
        return seconds.isFinite ? seconds : 0
    }

    /// Decode whatever the source is into the same mono AAC-in-CAF the
    /// recorder writes, so the transcriber sees one format regardless of
    /// origin. Sample rate is preserved; WhisperKit resamples anyway, and
    /// forcing a rate here would just cost quality on a 48k source.
    private static func transcode(
        track: AVAssetTrack, of asset: AVURLAsset, to url: URL
    ) async throws {
        let reader = try AVAssetReader(asset: asset)
        // Float32 non-interleaved: the same common format AVAudioFile wants,
        // so no second conversion between reader and writer.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
        ])
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? ImportError.noAudioTrack
        }

        var file: AVAudioFile?
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let frames = CMSampleBufferGetNumSamples(sample)
            guard frames > 0 else { continue }

            let desc = CMSampleBufferGetFormatDescription(sample)
            guard let asbd = desc.flatMap({
                CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
            }) else { continue }

            if file == nil {
                file = try AVAudioFile(
                    forWriting: url,
                    settings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: asbd.mSampleRate,
                        AVNumberOfChannelsKey: 1,
                    ],
                    commonFormat: .pcmFormatFloat32,
                    interleaved: false
                )
            }
            guard let file,
                  let format = AVAudioFormat(
                      commonFormat: .pcmFormatFloat32,
                      sampleRate: asbd.mSampleRate,
                      channels: 1,
                      interleaved: false
                  ),
                  let buffer = AVAudioPCMBuffer(
                      pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)
                  )
            else { continue }
            buffer.frameLength = AVAudioFrameCount(frames)

            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer
            ) == noErr, let pointer, let channel = buffer.floatChannelData?[0] else { continue }
            memcpy(channel, pointer, min(length, frames * MemoryLayout<Float>.size))
            try file.write(from: buffer)
        }

        if reader.status == .failed { throw reader.error ?? ImportError.noAudioTrack }
        // No frames at all is a file with an audio track that decodes to
        // nothing — a failure, not a silent zero-length recording.
        guard file != nil else { throw ImportError.noAudioTrack }
        // AVAudioFile flushes on deinit, and nothing else in this function
        // closes it. Without this the caller (and the queue behind it) reads
        // a 0-frame file and treats a good import as an empty recording —
        // verified: probing before the release reported 0 frames for a clip
        // that actually decoded to 132300.
        file = nil
    }

    #if DEBUG
    /// Round-trip a generated tone through the importer: the queue only ever
    /// gets mic.caf, so the one thing that must hold is that an arbitrary
    /// source lands as a readable mono CAF of the right length, and that a
    /// second import can't clobber it. The exporter rides along: the same
    /// tone goes back out as m4a, since an export nobody can open is the
    /// same failure as an import nobody can make.
    nonisolated(unsafe) private static var checked = false

    static func selfCheck() async {
        guard !checked else { return }
        checked = true
        let box = FileManager.default.temporaryDirectory
            .appendingPathComponent("quill-import-\(UUID().uuidString)", isDirectory: true)
        let dir = box.appendingPathComponent("2026.01.01-0900", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(#"{"kind":"note","started":"2026-01-01T09:00:00Z"}"#.utf8)
            .write(to: dir.appendingPathComponent("meta.json"), options: .atomic)

        // A 2-second 440Hz tone as a source file.
        let src = box.appendingPathComponent("tone.caf")
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false
        ), let tone = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 88_200) else { return }
        tone.frameLength = 88_200
        for i in 0..<88_200 {
            tone.floatChannelData?[0][i] = sin(2 * .pi * 440 * Float(i) / 44_100) * 0.5
        }
        guard let out = try? AVAudioFile(
            forWriting: src,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            ],
            commonFormat: .pcmFormatFloat32, interleaved: false
        ) else { return }
        try? out.write(from: tone)

        guard let seconds = try? await into(dir, from: src) else {
            assertionFailure("import of a plain tone threw")
            return
        }
        assert(abs(seconds - 2) < 0.5, "duration came back as \(seconds), expected ~2")
        let written = dir.appendingPathComponent("mic.caf")
        guard let probe = try? AVAudioFile(forReading: written) else {
            assertionFailure("imported mic.caf is not readable by the transcriber's reader")
            return
        }
        assert(probe.length > 0, "imported mic.caf decoded to zero frames")
        assert(probe.fileFormat.channelCount == 1, "import must be mono like the recorder's output")
        // No .part file survives a successful import.
        assert(
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf.part").path),
            "temp file left behind"
        )
        // A second import must refuse rather than replace real audio.
        do {
            _ = try await into(dir, from: src)
            assertionFailure("second import overwrote existing audio")
        } catch {}

        // …and straight back out: the share sheet gets an .m4a, not the .caf.
        guard let exported = try? await AudioExport.m4a(of: dir, named: "tone check") else {
            assertionFailure("export of a freshly imported session threw")
            return
        }
        assert(exported.pathExtension == "m4a", "exported \(exported.lastPathComponent), not m4a")
        assert(exported.lastPathComponent == "tone check.m4a", "title did not name the file")
        guard let back = try? AVAudioFile(forReading: exported) else {
            assertionFailure("exported m4a is not readable — nothing else will open it either")
            return
        }
        let exportedSeconds = Double(back.length) / back.fileFormat.sampleRate
        assert(abs(exportedSeconds - 2) < 0.5, "export came back as \(exportedSeconds)s, expected ~2")

        // Titles are free text and go straight into a path.
        assert(AudioExport.filename(from: "weekly planning · pricing") == "weekly planning · pricing")
        assert(!AudioExport.filename(from: "9/13 sync").contains("/"), "a slash would write outside the box")
        assert(AudioExport.filename(from: "   ") == "recording", "blank title must not make a dotfile")
        assert(AudioExport.filename(from: "").isEmpty == false)
        assert(AudioExport.filename(from: String(repeating: "x", count: 400)).count == 100)
    }
    #endif
}

/// The other direction: hand the raw audio to Voice Memos, Files, another
/// recording app, or a Mac over AirDrop.
///
/// quill keeps `mic.caf` forever and promises never to replace it, but a CAF
/// is a container almost nothing outside Apple's own frameworks will open —
/// exporting it as-is is technically "your audio" and practically a file the
/// user can't use. So the export transcodes to `.m4a`, which every recording
/// app, DAW, and browser takes.
enum AudioExport {
    enum ExportError: LocalizedError {
        case noAudio
        case failed(Error?)

        var errorDescription: String? {
            switch self {
            case .noAudio: return "this session has no audio to export"
            case .failed(let e):
                return "couldn't export the audio: \(e?.localizedDescription ?? "unknown error")"
            }
        }
    }

    /// Transcode `dir/mic.caf` to an m4a in a fresh temp box, named after the
    /// session so it lands in Files as `weekly planning.m4a` rather than
    /// `mic.m4a`. Returns the file to hand to the share sheet.
    ///
    /// ponytail: a temp box per export, reaped by iOS — nothing to clean up,
    /// nothing to collide with, same as `SessionActions.zip`.
    static func m4a(of dir: URL, named title: String) async throws -> URL {
        let source = dir.appendingPathComponent("mic.caf")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw ExportError.noAudio
        }

        let box = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let dst = box.appendingPathComponent("\(filename(from: title)).m4a")

        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ExportError.failed(nil)
        }

        if #available(iOS 18.0, *) {
            try await export.export(to: dst, as: .m4a)
        } else {
            export.outputURL = dst
            export.outputFileType = .m4a
            await export.export()
            guard export.status == .completed else {
                throw ExportError.failed(export.error)
            }
        }
        return dst
    }

    /// A session title is free text — it can hold "/" (which would silently
    /// write into a directory that isn't there) or be empty after a rename.
    /// Neither is worth an error dialog, so both fall back.
    static func filename(from title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:\0"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 100 chars leaves room under every filesystem limit without cutting
        // a real title short.
        let clipped = String(cleaned.prefix(100))
        return clipped.isEmpty ? "recording" : clipped
    }
}
