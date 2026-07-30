import AVFoundation
import Foundation
@preconcurrency import WhisperKit

/// DEV-only bake-off: run one audio file through every catalog model,
/// timing each, and write Documents/benchmark.md. Triggered by the
/// `--benchmark` launch argument (dev builds) or the DEV settings row.
enum ModelBenchmark {
    static var shouldRunOnLaunch: Bool {
        DevSettings.isDevBuild
            && CommandLine.arguments.contains("--benchmark")
    }

    /// Newest session folder that has audio.
    static func latestAudio(root: URL) -> URL? {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return dirs
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .first { fm.fileExists(atPath: $0.appendingPathComponent("mic.caf").path) }?
            .appendingPathComponent("mic.caf")
    }

    /// " (0.38x realtime)" — the ratio any public perf claim should be quoting,
    /// so nobody has to reconstruct it from a clip that may not exist later.
    /// Empty when the duration couldn't be read, rather than inventing a ratio.
    static func realtime(_ compute: TimeInterval, of audioSeconds: Double?) -> String {
        guard let a = audioSeconds, a > 0 else { return "" }
        return String(format: " (%.2fx realtime)", compute / a)
    }

    static func run(root: URL, progress: @escaping @Sendable (String) -> Void) async {
        guard let audio = latestAudio(root: root) else {
            progress("benchmark: no audio found")
            return
        }

        // Without the clip's length the transcribe times below are unauditable:
        // "3.0s" only means something against "3.0s of what". The clip the first
        // bake-off ran on is already gone, which retroactively cost us the
        // "~3s per 8s of audio" figure quoted in README.md and the landing page.
        let audioSeconds = (try? await AVURLAsset(url: audio).load(.duration))
            .map { CMTimeGetSeconds($0) }
        var report = ["# whisper model bake-off", "",
                      "audio: \(audio.deletingLastPathComponent().lastPathComponent)/mic.caf",
                      "duration: \(audioSeconds.map { String(format: "%.1fs", $0) } ?? "unknown")", ""]

        for model in ModelCatalog.models {
            progress("benchmark: \(model.label) — downloading/loading")
            let t0 = Date()
            do {
                let folder = try await WhisperKit.download(variant: model.id)
                let loaded = Date()
                let pipe = try await WhisperKit(
                    WhisperKitConfig(model: model.id, modelFolder: folder.path)
                )
                progress("benchmark: \(model.label) — transcribing")

                let language = (try? await pipe.detectLanguage(audioPath: audio.path))?.language
                let options = DecodingOptions(
                    task: .transcribe,
                    language: language,
                    usePrefillPrompt: language != nil,
                    detectLanguage: language == nil,
                    chunkingStrategy: .vad
                )
                let tTranscribe = Date()
                let results = try await pipe.transcribe(audioPath: audio.path, decodeOptions: options)
                let done = Date()

                let text = results
                    .flatMap { $0.segments }
                    .map {
                        $0.text.replacingOccurrences(
                            of: "<\\|[^|]*\\|>", with: "", options: .regularExpression
                        )
                    }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                report += [
                    "## \(model.label) (\(model.id))",
                    "",
                    "- load: \(String(format: "%.1f", loaded.timeIntervalSince(t0)))s (incl. download if any)",
                    "- transcribe: \(String(format: "%.1f", done.timeIntervalSince(tTranscribe)))s"
                        + realtime(done.timeIntervalSince(tTranscribe), of: audioSeconds),
                    "- language: \(language ?? "?")",
                    "",
                    "> \(text)",
                    "",
                ]
            } catch {
                report += ["## \(model.label)", "", "FAILED: \(error)", ""]
            }
        }

        let out = root.deletingLastPathComponent().appendingPathComponent("benchmark.md")
        try? Data(report.joined(separator: "\n").utf8).write(to: out, options: .atomic)
        progress("benchmark: done → benchmark.md")
    }
}
