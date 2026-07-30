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

    static func run(root: URL, progress: @escaping @Sendable (String) -> Void) async {
        guard let audio = latestAudio(root: root) else {
            progress("benchmark: no audio found")
            return
        }

        var report = ["# whisper model bake-off", "",
                      "audio: \(audio.deletingLastPathComponent().lastPathComponent)/mic.caf", ""]

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
                    "- transcribe: \(String(format: "%.1f", done.timeIntervalSince(tTranscribe)))s",
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
