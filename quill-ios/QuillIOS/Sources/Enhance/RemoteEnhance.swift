import Foundation

/// Notes structured by a remote model — Anthropic or OpenAI shaped, at any
/// endpoint the user points it at (the vendor's own, a proxy, a relay, or a
/// server on their LAN).
///
/// This is the one place in quill where anything leaves the phone, so the
/// boundary is drawn narrowly and on purpose:
///
/// - **Audio never goes.** `mic.caf` is not read here and never will be —
///   transcription stays on WhisperKit, on-device, always. What crosses the
///   network is the transcript text (plus OCR text from attached images),
///   the same input the two local backends get.
/// - **Off by default.** Requires both an explicit toggle and a key the user
///   pasted. `isAvailable` is false otherwise, so the fallback chain skips
///   this and behaves exactly as it did before the feature existed.
///
/// It sits FIRST in the chain when enabled: a user who opted in and is paying
/// per token wants the model they chose, not a local one that happened to
/// answer.
///
/// ponytail: `RemoteShape` (an enum over two wire formats) is the whole
/// provider layer. quill needs one non-streaming completion for one task —
/// transcript → notes.md — so `EnhanceService` + a shape enum covers it. No
/// provider registry, no per-instance config, no model catalog.
struct RemoteEnhance: EnhanceService {
    /// Opt-in switch, settings-owned. Separate from "is a key present" so
    /// turning it off doesn't destroy the key the user pasted.
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "quill.remoteEnhance")
    }

    static var shape: RemoteShape {
        UserDefaults.standard.string(forKey: "quill.remoteShape")
            .flatMap(RemoteShape.init(rawValue:)) ?? .anthropic
    }

    /// Blank means the shape's own default, so switching Anthropic → OpenAI
    /// moves the endpoint and model with it instead of pointing an OpenAI
    /// request at api.anthropic.com.
    static var baseURL: String {
        let custom = UserDefaults.standard.string(forKey: "quill.remoteBaseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (custom?.isEmpty == false ? custom! : shape.defaultBaseURL)
    }

    static var model: String {
        let custom = UserDefaults.standard.string(forKey: "quill.remoteModel")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (custom?.isEmpty == false ? custom! : shape.defaultModel)
    }

    var isAvailable: Bool { Self.isEnabled && RemoteCredential.key != nil }

    /// Why it can't run, for the settings row and the session screen.
    static var unavailableReason: String? {
        if !isEnabled { return "remote notes are off" }
        if RemoteCredential.key == nil { return "add an API key to use remote notes" }
        return nil
    }

    func enhance(session dir: URL) async throws {
        guard let key = RemoteCredential.key else { throw RemoteError.noKey }
        let transcriptURL = dir.appendingPathComponent("transcript.md")
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
              !transcript.isEmpty else { return }

        // A remote model's context dwarfs the on-device 4k window, so the
        // 8k-char clip the local backends need would throw away most of a long
        // meeting for no reason. 400k chars is still bounded — an unbounded
        // send is an unbounded bill.
        let clipped = String(transcript.prefix(400_000))

        // Same prompts as both local backends, so notes don't change voice
        // depending on which one answered.
        let system = FoundationModelsEnhance.prompt
            + (await FoundationModelsEnhance.imageContext(dir))
        let notes = try await Self.complete(
            system: system, user: clipped, maxTokens: 4_000, key: key
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return }

        try Data((notes + "\n").utf8)
            .write(to: dir.appendingPathComponent("notes.md"), options: .atomic)

        // Title as a second call rather than a second turn: no conversation
        // state to carry, and a failure here must not cost the notes.
        if let title = try? await Self.complete(
            system: FoundationModelsEnhance.titlePrompt,
            user: String(notes.prefix(2_000)),
            maxTokens: 64,
            key: key
        ) {
            FoundationModelsEnhance.saveTitle(title, in: dir)
        }
    }

    // MARK: - One completion

    enum RemoteError: LocalizedError {
        case noKey
        case http(status: Int, body: String)
        case empty

        var errorDescription: String? {
            switch self {
            case .noKey:
                return "no API key — add one in settings"
            case .http(let status, let body):
                // The server's own message is the useful part (bad key, no
                // credit, unknown model); a bare 404 isn't. 404 in particular
                // is almost always a wrong endpoint or model name, and saying
                // so saves the round of guessing.
                let hint = status == 404
                    ? " · check the endpoint and model name"
                    : ""
                let detail = body.isEmpty ? "" : " · \(body.prefix(200))"
                return "remote notes failed (\(status))\(detail)\(hint)"
            case .empty:
                return "the model returned nothing"
            }
        }
    }

    static func complete(
        system: String,
        user: String,
        maxTokens: Int,
        key: String,
        shape: RemoteShape = shape,
        base: String = baseURL,
        model: String = model
    ) async throws -> String {
        #if DEBUG
        RemoteCredential.selfCheck()
        RemoteShape.selfCheckShapes()
        RemoteModels.selfCheck()
        #endif

        var request = URLRequest(url: shape.completionURL(base: base))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        shape.authorize(&request, key: key)
        // A structuring pass over a long meeting is slow; the 60s default cuts
        // it off mid-answer and reads to the user as a failure.
        request.timeoutInterval = 180
        request.httpBody = try JSONSerialization.data(
            withJSONObject: shape.body(
                system: system, user: user, model: model, maxTokens: maxTokens
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw RemoteError.http(status: status, body: shape.parseError(data))
        }
        let text = shape.parseCompletion(data)
        guard !text.isEmpty else { throw RemoteError.empty }
        return text
    }

    /// One cheap round-trip for the settings "test" button — the smallest
    /// possible completion, so a wrong key or endpoint is found while the user
    /// is still looking at the field rather than after a 40-minute recording.
    static func verify(key: String) async -> String? {
        do {
            _ = try await complete(
                system: "Reply with the single word: ok",
                user: "ping",
                maxTokens: 16,
                key: key
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
