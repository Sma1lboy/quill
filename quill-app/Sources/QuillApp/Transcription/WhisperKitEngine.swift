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
    /// User's allow-set from config (`transcription.languages`), already
    /// filtered to codes whisper knows. Empty = auto-detect.
    private let selected: [String]

    init(languages: [String] = []) {
        // Validate at the config boundary — a typo'd code silently degrading to
        // auto-detect is the failure mode worth a warning.
        let known = languages.filter {
            Constants.languageCodes.contains($0.hasPrefix("zh") ? "zh" : $0)
        }
        for bad in languages where !known.contains(bad) {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription language \"\(bad)\" — ignoring\n".utf8
            ))
        }
        selected = known
    }

    /// Which language token to prefill, and whether zh output needs script
    /// normalization. Empty allow-set = trust detection; one entry forces it;
    /// several restrict detection's argmax to the set (mixed-language
    /// speakers). Pure — see `selfCheck()`.
    static func resolve(
        selected: [String],
        detected: (language: String, langProbs: [String: Float])?
    ) -> (language: String?, zhTransform: StringTransform?) {
        // zh-Hans and zh-Hant are one "zh" to whisper; script is fixed after.
        let allowed = Set(selected.map { $0.hasPrefix("zh") ? "zh" : $0 })

        let language: String?
        if allowed.count == 1 {
            language = allowed.first
        } else if let detected {
            language = allowed.isEmpty
                ? detected.language
                : detected.langProbs
                    .filter { allowed.contains($0.key) }
                    .max { $0.value < $1.value }?.key
                    ?? detected.language
        } else {
            language = nil
        }

        // Whisper's single "zh" token emits Simplified or Traditional at
        // random — pin it to the chosen script (default Hans).
        let zh: StringTransform? = language == "zh"
            ? (selected.contains("zh-Hant")
                ? StringTransform("Hans-Hant")
                : StringTransform("Hant-Hans"))
            : nil
        return (language, zh)
    }

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

        // Ask with no detection first: if the allow-set already pins a single
        // language, the detection pass is wasted work. Reusing resolve for the
        // question keeps the pinning rule in exactly one place.
        var (language, zhTransform) = Self.resolve(selected: selected, detected: nil)
        if language == nil,
           let detected = try? await pipe.detectLanguage(audioPath: audio.path) {
            (language, zhTransform) = Self.resolve(selected: selected, detected: detected)
        }

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
                var text = seg.text
                    .replacingOccurrences(
                        of: "<\\|[^|]*\\|>", with: "", options: .regularExpression
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                if let zhTransform {
                    text = text.applyingTransform(zhTransform, reverse: false) ?? text
                }
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

#if DEBUG
extension WhisperKitEngine {
    /// Language allow-set resolution, the only non-trivial branch here.
    /// Called once from AppMain at launch.
    static func selfCheck() {
        let det = (language: "en", langProbs: ["en": Float(0.7), "zh": 0.2, "ja": 0.1])

        // Empty allow-set trusts detection; no zh transform.
        var r = resolve(selected: [], detected: det)
        assert(r.language == "en" && r.zhTransform == nil)

        // One entry forces it even against detection, and zh normalizes.
        r = resolve(selected: ["zh-Hant"], detected: det)
        assert(r.language == "zh" && r.zhTransform == StringTransform("Hans-Hant"))
        r = resolve(selected: ["zh-Hans"], detected: nil)
        assert(r.language == "zh" && r.zhTransform == StringTransform("Hant-Hans"))

        // Several entries restrict detection's argmax to the set.
        r = resolve(selected: ["zh-Hans", "ja"], detected: det)
        assert(r.language == "zh" && r.zhTransform == StringTransform("Hant-Hans"))

        // Detection landing outside the set falls back to its own pick
        // rather than dropping the transcript.
        r = resolve(selected: ["de", "fr"], detected: det)
        assert(r.language == "en")

        // No detection and no pin: let whisper detect inline.
        assert(resolve(selected: [], detected: nil).language == nil)
    }
}
#endif
