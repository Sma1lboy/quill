import Foundation

/// Post-transcription LLM pass: feed transcript.md to a local LLM CLI and
/// write the structured result as notes.md next to it. The command gets the
/// prompt+transcript on stdin and must print markdown to stdout — the
/// default is `claude -p`, but any stdin→stdout CLI works (ollama, llm, …).
enum NotesStructurer {
    enum StructureError: Error, CustomStringConvertible {
        case missingTranscript(URL)
        case commandFailed(String, Int32, String)
        case timedOut(String, TimeInterval)

        var description: String {
            switch self {
            case .missingTranscript(let url):
                return "no transcript.md at \(url.path)"
            case .commandFailed(let cmd, let code, let stderr):
                // 127 is the shell's "not found" — the common case when quill
                // runs as a LaunchAgent and `claude` isn't on the login PATH.
                let hint = code == 127 ? " (command not found on PATH)" : ""
                return "llm command `\(cmd)` exited \(code)\(hint): \(stderr.prefix(300))"
            case .timedOut(let cmd, let after):
                return "llm command `\(cmd)` still running after \(Int(after))s — killed"
            }
        }
    }

    /// Wall-clock ceiling for the structuring subprocess. A local LLM chewing a
    /// two-hour transcript is slow but not 15-minutes slow, and an interactive
    /// CLI misconfigured to prompt for input would otherwise wedge the queue
    /// forever — nothing else transcribes while this blocks.
    /// ponytail: one fixed ceiling, not a config key, until someone hits it.
    static let timeout: TimeInterval = 900

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

        // Armed before the write: a command that never drains stdin blocks us
        // once the pipe buffer fills, and one that never exits blocks the reads
        // below. Killing it closes both pipes and unblocks whichever we're in.
        let started = Date()
        let deadline = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }

        // Throwing write, not `write(_:)`: if the command doesn't exist the
        // shell has already exited by now and this pipe has no reader. The
        // ObjC `write` raises on EPIPE; this one throws. (SIGPIPE itself is
        // ignored process-wide in AppMain — otherwise it kills quill outright.)
        try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
        try? stdin.fileHandleForWriting.close()

        // Read before wait — a transcript bigger than the pipe buffer would
        // deadlock the child otherwise.
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        // ponytail: inferring "we killed it" from the clock rather than
        // synchronizing a flag with the timer queue. A command that dies of an
        // unrelated signal exactly at the deadline gets mislabeled; the
        // alternative is a lock for a log string.
        if task.terminationReason == .uncaughtSignal,
           Date().timeIntervalSince(started) >= timeout {
            throw StructureError.timedOut(cmd, timeout)
        }

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
