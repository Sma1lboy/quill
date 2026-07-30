import Foundation

/// Substring search over every session's transcript.json. Ported from the iOS
/// sibling (QuillIOS/Sources/UI/SearchView.swift) — same Foundation compare
/// options and the same snippet windowing, so a query behaves identically on
/// both platforms. Only the row rendering differs.
enum TranscriptSearch {
    struct Hit: Identifiable, Hashable, Sendable {
        let sessionID: String
        let sessionTitle: String
        let dir: URL
        let startMS: Int
        /// Index into `Transcript.segments` — kept so a hit is addressable
        /// even though the popover opens the whole file.
        let segment: Int
        /// Snippet split around the match so the row can tint the middle.
        let before: String
        let match: String
        let after: String

        var id: String { "\(sessionID)#\(segment)" }
    }

    /// Foundation does the normalization — never hand-roll it.
    static var options: String.CompareOptions { [.caseInsensitive, .diacriticInsensitive] }

    /// ponytail: linear scan decoding every session's transcript.json per
    /// query. Build an index if libraries pass ~1k sessions.
    ///
    /// Scans the whole library rather than `state.sessions` — that list is
    /// capped for display and search shouldn't inherit a display limit.
    static func scan(root: URL, query: String, limit: Int = 100) -> [Hit] {
        var hits: [Hit] = []
        for session in SessionSummary.scan(root: root, limit: .max) {
            guard let transcript = Transcript.read(from: session.dir) else { continue }
            for (i, seg) in transcript.segments.enumerated() {
                // First match per segment only — one row per segment reads best.
                guard let range = seg.text.range(of: query, options: options) else { continue }
                let (before, match, after) = snippet(seg.text, range)
                hits.append(Hit(
                    sessionID: session.id,
                    sessionTitle: session.title,
                    dir: session.dir,
                    startMS: seg.start_ms,
                    segment: i,
                    before: before,
                    match: match,
                    after: after
                ))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Window the segment down to roughly one popover line around the match,
    /// eliding what we cut. Grapheme-safe: all offsets go through String.Index.
    static func snippet(
        _ text: String, _ match: Range<String.Index>, lead: Int = 20, trail: Int = 60
    ) -> (before: String, match: String, after: String) {
        let start = text.index(match.lowerBound, offsetBy: -lead, limitedBy: text.startIndex)
            ?? text.startIndex
        let end = text.index(match.upperBound, offsetBy: trail, limitedBy: text.endIndex)
            ?? text.endIndex
        var before = String(text[start..<match.lowerBound])
        var after = String(text[match.upperBound..<end])
        if start != text.startIndex { before = "…" + before }
        if end != text.endIndex { after += "…" }
        return (before, String(text[match]), after)
    }
}

#if DEBUG
extension TranscriptSearch {
    /// The one runnable check: folding, slice fidelity, elision, CJK offsets.
    static func selfCheck() {
        let text = "Café au lait was the topic — résumé review followed after that."
        guard let r = text.range(of: "cafe", options: options) else {
            assertionFailure("case+diacritic-insensitive match failed")
            return
        }
        let latin = snippet(text, r, lead: 4, trail: 6)
        assert(latin.match == "Café", "match slice lost the source text: \(latin.match)")
        assert(latin.before.isEmpty, "unexpected lead window: \(latin.before)")
        assert(latin.after.hasSuffix("…"), "long tail not elided: \(latin.after)")
        assert(text.range(of: "zzz", options: options) == nil, "false positive")

        // Multi-byte offsets must go through String.Index, not utf8 counts.
        let zh = "今天我们讨论定价策略和路线图"
        guard let r2 = zh.range(of: "定价", options: options) else {
            assertionFailure("zh substring match failed")
            return
        }
        let cjk = snippet(zh, r2, lead: 3, trail: 3)
        assert(cjk.match == "定价", "multi-byte match slice broke: \(cjk.match)")
        assert(cjk.before == "…们讨论", "multi-byte lead window broke: \(cjk.before)")

        // Regex metacharacters are literals here — `range(of:)` without
        // .regularExpression must not treat these as patterns.
        assert(text.range(of: ".*", options: options) == nil, "'.*' matched as regex")
        assert(text.range(of: "^Caf", options: options) == nil, "'^' matched as anchor")
        // An emoji query must slice on grapheme boundaries, not scalars.
        let emoji = "recording 🎙️ live"
        if let r3 = emoji.range(of: "🎙️", options: options) {
            assert(snippet(emoji, r3).match == "🎙️", "emoji match slice broke")
        } else {
            assertionFailure("emoji query failed to match")
        }
    }
}
#endif
