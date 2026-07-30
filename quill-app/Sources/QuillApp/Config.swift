import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": {
///         "enabled": true,
///         "engine": "whisperkit",
///         "languages": ["en", "zh-Hans"]
///       },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook",
///       "notes": { "enabled": true, "command": "claude -p", "prompt": "…" }
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. Only "whisperkit" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "whisperkit"
    }

    /// Whisper language allow-set. Empty (or absent) = auto-detect per
    /// recording; one entry forces it; several restrict detection to that set.
    /// `zh-Hans`/`zh-Hant` are both "zh" to whisper — the chosen script is
    /// enforced by ICU transform on the output, same as iOS.
    static func transcriptionLanguages() -> [String] {
        (transcription()?["languages"] as? [String])?.filter { !$0.isEmpty } ?? []
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    /// Whether transcripts get an LLM structuring pass into notes.md. Default on.
    static func notesEnabled() -> Bool {
        notes()?["enabled"] as? Bool ?? true
    }

    /// Shell command that reads prompt+transcript on stdin and prints
    /// structured markdown on stdout.
    static func llmCommand() -> String {
        (notes()?["command"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "claude -p"
    }

    /// Structuring prompt; the transcript is appended after it.
    static func llmPrompt() -> String {
        (notes()?["prompt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? NotesStructurer.defaultPrompt
    }

    private static func notes() -> [String: Any]? {
        load()?["notes"] as? [String: Any]
    }

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
