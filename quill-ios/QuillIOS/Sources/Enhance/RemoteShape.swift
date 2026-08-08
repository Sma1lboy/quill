import Foundation

/// The wire protocol the remote endpoint speaks.
///
/// These two shapes cover essentially every endpoint a user will point quill
/// at: Anthropic and OpenAI directly, and the large majority of proxies,
/// relays, gateways and local servers (Ollama, vLLM, LM Studio, LiteLLM,
/// OpenRouter, Groq, DeepSeek, Moonshot…), which almost all speak one of the
/// two. quill needs one non-streaming completion, so this enum is the whole
/// provider layer — auth header, URL, request body, response shape.
///
/// ponytail: an enum, not a protocol with two conformances. There is no third
/// axis of variation and nothing to inject; a `switch` over two cases in four
/// small functions is less code than the type ceremony would be.
enum RemoteShape: String, CaseIterable, Codable {
    case anthropic
    case openAI

    var label: String {
        switch self {
        case .anthropic: return "anthropic"
        case .openAI: return "openai"
        }
    }

    /// What the field placeholders should suggest for this shape.
    var defaultBaseURL: String {
        switch self {
        case .anthropic: return "https://api.anthropic.com"
        case .openAI: return "https://api.openai.com"
        }
    }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-5"
        case .openAI: return "gpt-5"
        }
    }

    /// Endpoints served by proxies and vendors that speak the other shape —
    /// shown as a hint so the section doesn't read as "Anthropic or OpenAI only".
    var compatibilityHint: String {
        switch self {
        case .anthropic:
            return "anthropic api and compatible relays"
        case .openAI:
            return "openai, and most proxies / local servers (ollama, vllm, lm studio, openrouter…)"
        }
    }

    // MARK: - URLs

    /// `<base>/v1/<path>`, tolerating a base typed with or without a trailing
    /// slash or an existing `/v1`. A base with its own subpath keeps it, so a
    /// relay at `https://relay.example.com/anthropic` works.
    func url(base: String, path: String) -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix("/v1") { trimmed.removeLast(3) }
        return URL(string: trimmed + "/v1/" + path)
            ?? URL(string: defaultBaseURL + "/v1/" + path)!
    }

    func completionURL(base: String) -> URL {
        url(base: base, path: self == .anthropic ? "messages" : "chat/completions")
    }

    /// Both shapes converged on `/v1/models`.
    func modelsURL(base: String) -> URL {
        url(base: base, path: "models")
    }

    // MARK: - Auth

    /// Marketing version for the user-agent, nonisolated so any actor can
    /// build a request.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func authorize(_ request: inout URLRequest, key: String) {
        switch self {
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        // quill identifies itself honestly. Impersonating another client to
        // unlock server behavior withheld from third parties is declined —
        // see the settled decision in TODO.md.
        //
        // Read from the bundle directly rather than through `UpdateChecker`:
        // that type is @MainActor, and this runs on the transcription actor.
        request.setValue("quill-ios/\(Self.version)", forHTTPHeaderField: "User-Agent")
    }

    // MARK: - Body

    func body(system: String, user: String, model: String, maxTokens: Int) -> [String: Any] {
        switch self {
        case .anthropic:
            return [
                "model": model,
                "max_tokens": maxTokens,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
        case .openAI:
            // System-as-a-message, and `max_completion_tokens`: the newer
            // OpenAI models reject `max_tokens` outright, while every
            // OpenAI-compatible proxy still accepts the newer key.
            return [
                "model": model,
                "max_completion_tokens": maxTokens,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ]
        }
    }

    // MARK: - Parsing

    /// The assistant text, or "" when the payload has none.
    func parseCompletion(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "" }
        switch self {
        case .anthropic:
            // content: [{type: "text", text: "…"}, …] — thinking blocks and
            // tool blocks also live here, so filter by type rather than
            // taking [0] and hoping.
            let blocks = json["content"] as? [[String: Any]] ?? []
            return blocks
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
        case .openAI:
            let choices = json["choices"] as? [[String: Any]] ?? []
            let message = choices.first?["message"] as? [String: Any]
            return message?["content"] as? String ?? ""
        }
    }

    /// The server's own error message, which is the part worth showing (bad
    /// key, no credit, unknown model). Both shapes nest it under `error`.
    func parseError(_ data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return String(data: data, encoding: .utf8) ?? "" }
        if let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Model IDs. Both shapes return `{"data":[{"id":…}]}`; a few proxies
    /// return a bare array, which costs one line to also accept.
    func parseModels(_ data: Data) -> [String] {
        let root = try? JSONSerialization.jsonObject(with: data)
        let entries = (root as? [String: Any])?["data"] as? [[String: Any]]
            ?? root as? [[String: Any]]
            ?? []
        return entries.compactMap { $0["id"] as? String }
    }

    #if DEBUG
    /// The per-shape wiring, since a mismatch here fails only against a real
    /// server: an OpenAI body sent to `/v1/messages`, or an Anthropic reply
    /// read as `choices[0]`, both surface as "remote notes never work".
    static func selfCheckShapes() {
        assert(anthropic.completionURL(base: "https://api.anthropic.com").absoluteString
            == "https://api.anthropic.com/v1/messages")
        assert(openAI.completionURL(base: "https://api.openai.com/v1/").absoluteString
            == "https://api.openai.com/v1/chat/completions")
        assert(openAI.modelsURL(base: "http://localhost:11434").absoluteString
            == "http://localhost:11434/v1/models")
        // A relay on a subpath keeps it.
        assert(anthropic.completionURL(base: "https://relay.example.com/anthropic").absoluteString
            == "https://relay.example.com/anthropic/v1/messages")
        // Garbage falls back instead of crashing the notes pass.
        assert(openAI.completionURL(base: "not a url").absoluteString.hasSuffix("/v1/chat/completions"))

        // Bodies carry the key each shape actually requires.
        let a = anthropic.body(system: "s", user: "u", model: "m", maxTokens: 10)
        assert(a["system"] as? String == "s" && a["max_tokens"] as? Int == 10)
        assert((a["messages"] as? [[String: String]])?.count == 1, "anthropic takes system out of messages")
        let o = openAI.body(system: "s", user: "u", model: "m", maxTokens: 10)
        assert(o["max_completion_tokens"] as? Int == 10, "newer OpenAI models reject max_tokens")
        assert(o["max_tokens"] == nil)
        assert((o["messages"] as? [[String: String]])?.count == 2, "openai carries system as a message")

        // Responses, including the blocks that must NOT be taken as the answer.
        let aReply = Data(#"{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"notes"}]}"#.utf8)
        assert(anthropic.parseCompletion(aReply) == "notes", "thinking block leaked into notes")
        let oReply = Data(#"{"choices":[{"message":{"role":"assistant","content":"notes"}}]}"#.utf8)
        assert(openAI.parseCompletion(oReply) == "notes")
        assert(openAI.parseCompletion(Data("{}".utf8)).isEmpty)
        assert(anthropic.parseCompletion(Data("<html>".utf8)).isEmpty)

        // The server's message is what the user needs to see.
        let err = Data(#"{"error":{"type":"invalid_request_error","message":"credit balance is too low"}}"#.utf8)
        assert(anthropic.parseError(err).contains("credit balance"))
        assert(openAI.parseError(err).contains("credit balance"))

        // A bare-array model list (some proxies) parses too.
        assert(openAI.parseModels(Data(#"[{"id":"local-model"}]"#.utf8)) == ["local-model"])
    }
    #endif
}
