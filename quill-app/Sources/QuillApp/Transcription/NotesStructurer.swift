import Foundation

/// Post-transcription LLM pass: feed transcript.md to a local LLM CLI and
/// write the structured result as notes.md next to it. The command gets the
/// prompt+transcript on stdin and must print markdown to stdout — the
/// default is `claude -p`, but any stdin→stdout CLI works (ollama, llm, …).
enum NotesStructurer {
    enum StructureError: Error, CustomStringConvertible {
        case missingTranscript(URL)
        case commandFailed(String, Int32, String)

        var description: String {
            switch self {
            case .missingTranscript(let url):
                return "no transcript.md at \(url.path)"
            case .commandFailed(let cmd, let code, let stderr):
                return "llm command `\(cmd)` exited \(code): \(stderr.prefix(300))"
            }
        }
    }

    static let defaultPrompt = """
    You are given a meeting transcript ("me" is the machine's owner, "them" \
    is everyone else on the call). Produce structured meeting notes in \
    markdown with exactly these sections, and reply in the transcript's \
    dominant language:

    ## Summary
    2-4 sentences: what the meeting was about and its outcome.

    ## Key points
    Bulleted list of the substantive points discussed.

    ## Decisions
    Bulleted list of decisions made. Write "none" if there were none.

    ## Action items
    Bulleted list, each as `- [ ] owner — task`. Write "none" if there were none.

    Output only the markdown, no preamble.
    """

    /// Run the structuring pass for a finished session. Blocking — the
    /// coordinator already runs jobs serially off the main thread.
    static func structure(_ dir: URL) throws {
        let transcript = dir.appendingPathComponent("transcript.md")
        guard let text = try? String(contentsOf: transcript, encoding: .utf8) else {
            throw StructureError.missingTranscript(dir)
        }

        let cmd = Config.llmCommand()
        let input = Config.llmPrompt() + "\n\n---\n\n" + text

        let task = Process()
        task.launchPath = "/bin/sh"
        // Login shell so `claude` on the user's PATH resolves when quill runs
        // as a LaunchAgent (which inherits a minimal environment).
        task.arguments = ["-lc", cmd]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        try task.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()

        // Read before wait — a transcript bigger than the pipe buffer would
        // deadlock the child otherwise.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        let output = String(decoding: outData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.terminationStatus == 0, !output.isEmpty else {
            throw StructureError.commandFailed(
                cmd,
                task.terminationStatus,
                String(decoding: errData, as: UTF8.self)
            )
        }

        try Data((output + "\n").utf8)
            .write(to: dir.appendingPathComponent("notes.md"), options: .atomic)
    }
}
