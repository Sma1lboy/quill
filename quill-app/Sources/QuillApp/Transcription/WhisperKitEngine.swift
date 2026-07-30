import AVFoundation
import Foundation
@preconcurrency import WhisperKit

/// WhisperKit (OpenAI Whisper small, Core ML) — ~100 languages including
/// Chinese, fully on-device. Two-pass per file: detect the language, then
/// transcribe with an explicit language prefill (detection without prefill
/// sometimes slips into translate mode).
actor WhisperKitEngine: TranscriptionEngine {
    enum EngineError: Error, CustomStringConvertible {
        case notPrepared
        case unreadableAudio(URL, Error?)

        var description: String {
            switch self {
            case .notPrepared: return "whisperkit engine used before prepare()"
            case .unreadableAudio(let url, let e):
                return "unreadable or empty audio \(url.lastPathComponent)"
                    + (e.map { ": \($0)" } ?? "")
            }
        }
    }

    nonisolated let name = "whisperkit"
    nonisolated let model = "openai_whisper-small"

    private var pipe: WhisperKit?

    func prepare() async throws {
        guard pipe == nil else { return }
        let config = WhisperKitConfig(model: model)
        pipe = try await WhisperKit(config)
    }

    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        guard let pipe else { throw EngineError.notPrepared }

        // Empty/truncated tracks make AVFoundation raise an uncatchable ObjC
        // exception deep in the resampler — probe readability up front.
        do {
            let probe = try AVAudioFile(forReading: audio)
            guard probe.length > 0 else { throw EngineError.unreadableAudio(audio, nil) }
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.unreadableAudio(audio, error)
        }

        let language = (try? await pipe.detectLanguage(audioPath: audio.path))?.language

        let options = DecodingOptions(
            task: .transcribe,
            language: language,
            usePrefillPrompt: language != nil,
            detectLanguage: language == nil,
            wordTimestamps: false,
            chunkingStrategy: .vad
        )
        let results = try await pipe.transcribe(audioPath: audio.path, decodeOptions: options)

        var segments: [TranscriptSegment] = []
        for result in results {
            for seg in result.segments {
                let text = seg.text
                    .replacingOccurrences(
                        of: "<\\|[^|]*\\|>", with: "", options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(
                    start: TimeInterval(seg.start),
                    end: TimeInterval(seg.end),
                    text: text
                ))
            }
        }
        return segments.sorted { $0.start < $1.start }
    }

    func release() async {
        pipe = nil
    }
}
