import Foundation

/// Model discovery for the remote notes endpoint: ask it what it serves,
/// cache the answer, and match what the user typed against it.
///
/// Why a list at all — model IDs are unguessable and they move. A user on a
/// proxy has no way to know whether it exposes `claude-sonnet-5`,
/// `anthropic/claude-sonnet-5`, or `gpt-5`. Typing a wrong one produces a 404
/// at the end of a long recording, which is the worst possible moment to
/// learn it.
///
/// The list is a *suggestion*, never a gate: `RemoteEnhance` sends whatever
/// the user typed. A proxy that serves a model it doesn't list must still
/// work — refusing a model because our discovery call didn't mention it would
/// be inventing a failure the server never reported.
enum RemoteModels {
    /// One endpoint's model IDs plus when we asked.
    struct Listing: Codable, Equatable {
        let ids: [String]
        let fetched: Date

        /// 60 minutes. A model list changes on the order of weeks, and the
        /// user is typing into a text field — re-asking on every keystroke
        /// would be a request per character.
        static let ttl: TimeInterval = 60 * 60

        var isFresh: Bool { Date().timeIntervalSince(fetched) < Self.ttl }
    }

    // MARK: - Cache

    /// Keyed by endpoint + protocol, NOT by credential: the same proxy serves
    /// the same models to every key, and keying by credential would re-fetch
    /// after every key rotation for no new information.
    ///
    /// ponytail: UserDefaults, not a file — a few hundred short strings with a
    /// 60-minute life. No key material is ever stored here.
    private static func cacheKey(_ base: String, _ shape: RemoteShape) -> String {
        "quill.models.\(shape.rawValue).\(base)"
    }

    static func cached(base: String, shape: RemoteShape) -> Listing? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey(base, shape)),
              let listing = try? JSONDecoder().decode(Listing.self, from: data),
              listing.isFresh
        else { return nil }
        return listing
    }

    private static func store(_ listing: Listing, base: String, shape: RemoteShape) {
        guard let data = try? JSONEncoder().encode(listing) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey(base, shape))
    }

    /// Drop every cached listing — for the settings "refresh" affordance and
    /// after an endpoint change that the user expects to re-probe.
    static func clearCache() {
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("quill.models.") {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Fetch

    /// Model IDs the endpoint reports. Cached for an hour per endpoint;
    /// `force` re-asks and replaces the entry.
    ///
    /// Returns [] rather than throwing on a listing that fails: plenty of
    /// proxies implement `/messages` and not `/models`, and a missing catalog
    /// must not read as a broken endpoint. A real credential problem surfaces
    /// on the first notes run, with the server's own message.
    static func list(
        base: String, shape: RemoteShape, key: String, force: Bool = false
    ) async -> [String] {
        #if DEBUG
        selfCheck()
        #endif
        if !force, let cached = cached(base: base, shape: shape) { return cached.ids }

        var request = URLRequest(url: shape.modelsURL(base: base))
        // Short: this runs behind a settings field, and a proxy that hangs
        // must not leave a spinner up for the URLSession default of 60s.
        request.timeoutInterval = 15
        shape.authorize(&request, key: key)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
        else { return cached(base: base, shape: shape)?.ids ?? [] }

        let ids = shape.parseModels(data)
        guard !ids.isEmpty else { return [] }
        store(Listing(ids: ids, fetched: Date()), base: base, shape: shape)
        return ids
    }

    // MARK: - Matching

    /// Suggestions for what the user has typed so far.
    ///
    /// Prefix first (someone typing "claude-son" means the thing that starts
    /// that way), then substring — a proxy that namespaces everything as
    /// `anthropic/claude-sonnet-5` would otherwise return nothing for the only
    /// query a user would think to type. Both passes are case-insensitive
    /// because model IDs are lowercase by convention, not by rule.
    ///
    /// Empty query returns the whole list: the field is empty when the section
    /// opens, and that's exactly when seeing the options is most useful.
    static func matches(_ query: String, in ids: [String], limit: Int = 8) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return Array(ids.prefix(limit)) }

        var prefix: [String] = []
        var contains: [String] = []
        for id in ids {
            let lower = id.lowercased()
            if lower.hasPrefix(q) {
                prefix.append(id)
            } else if lower.contains(q) {
                contains.append(id)
            }
        }
        // An exact match is not a suggestion — the user already typed it, and
        // offering it back is a row that does nothing.
        if prefix.count == 1, prefix[0].lowercased() == q, contains.isEmpty { return [] }
        return Array((prefix + contains).prefix(limit))
    }

    #if DEBUG
    nonisolated(unsafe) private static var checked = false

    /// Matching and TTL are pure and are where the silent wrongness lives: a
    /// prefix-only match hides every namespaced proxy model, and an inverted
    /// freshness check either caches forever or never caches at all.
    static func selfCheck() {
        guard !checked else { return }
        checked = true

        let ids = [
            "claude-sonnet-5", "claude-opus-5", "claude-haiku-4-5-20251001",
            "gpt-5", "anthropic/claude-sonnet-5", "openai/gpt-5-mini",
        ]
        // Prefix beats substring in ordering.
        let m = matches("claude", in: ids)
        assert(m.first == "claude-sonnet-5", "prefix hits must come first, got \(m)")
        assert(m.contains("anthropic/claude-sonnet-5"), "namespaced model must still be reachable")
        // Case-insensitive both ways.
        assert(matches("CLAUDE-OPUS", in: ids).contains("claude-opus-5"))
        // A namespaced-only query still finds its model.
        assert(matches("openai/", in: ids) == ["openai/gpt-5-mini"])
        // Empty shows the catalog rather than nothing.
        assert(matches("", in: ids).count == min(6, 8))
        // Typing a complete id offers no redundant suggestion...
        assert(matches("gpt-5", in: ids).contains("openai/gpt-5-mini"), "substring siblings still offered")
        assert(matches("claude-opus-5", in: ids).isEmpty, "exact single match should not suggest itself")
        // ...and an unknown model yields nothing rather than a wrong guess.
        assert(matches("llama-3", in: ids).isEmpty)
        assert(matches("x", in: ids, limit: 2).count <= 2, "limit not honored")

        // TTL boundaries, both directions.
        assert(Listing(ids: ["a"], fetched: Date()).isFresh)
        assert(Listing(ids: ["a"], fetched: Date().addingTimeInterval(-59 * 60)).isFresh)
        assert(!Listing(ids: ["a"], fetched: Date().addingTimeInterval(-61 * 60)).isFresh)
        // A clock that jumped backwards must not produce an immortal entry.
        assert(Listing(ids: ["a"], fetched: Date().addingTimeInterval(3600)).isFresh)

        // Parsing, both shapes, including the junk a proxy actually returns.
        let openAI = Data(#"{"data":[{"id":"gpt-5"},{"id":"gpt-5-mini"}]}"#.utf8)
        assert(RemoteShape.openAI.parseModels(openAI) == ["gpt-5", "gpt-5-mini"])
        let anthropic = Data(#"{"data":[{"id":"claude-opus-5","type":"model"}]}"#.utf8)
        assert(RemoteShape.anthropic.parseModels(anthropic) == ["claude-opus-5"])
        assert(RemoteShape.openAI.parseModels(Data("not json".utf8)).isEmpty)
        assert(RemoteShape.openAI.parseModels(Data(#"{"data":[]}"#.utf8)).isEmpty)
        // An HTML error page served as 200 must parse to nothing, not crash.
        assert(RemoteShape.anthropic.parseModels(Data("<html>nope</html>".utf8)).isEmpty)
    }
    #endif
}
