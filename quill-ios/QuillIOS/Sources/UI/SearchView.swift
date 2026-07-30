import Foundation
import SwiftUI

/// Cross-session transcript search. Reached from the header magnifier; a hit
/// opens the session with its matching segment scrolled into view.
struct SearchView: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [TranscriptSearch.Hit] = []
    @State private var scanning = false

    var body: some View {
        NavigationStack {
            results
                .background(Theme.paper.ignoresSafeArea())
                .navigationTitle("search")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(Theme.paper, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("close") { dismiss() }
                            .font(Theme.mono(13))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .searchable(
                    text: $query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "search transcripts"
                )
                .navigationDestination(for: TranscriptSearch.Hit.self) { hit in
                    SessionDetailView(state: state, id: hit.sessionID, scrollToSegment: hit.segment)
                }
        }
        .tint(Theme.accent)
        .task(id: query) { await search() }
        .task {
            #if DEBUG
            TranscriptSearch.selfCheck()
            #endif
        }
    }

    @ViewBuilder
    private var results: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            twoLines("search every transcript", "case and accent insensitive · on-device")
        } else if scanning {
            HStack(spacing: 8) {
                BrailleSpinner(size: 12)
                Text("scanning transcripts")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 48)
        } else if hits.isEmpty {
            twoLines("no matches", "transcripts only · notes aren't indexed")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Theme.kicker("matches")
                        Spacer()
                        Text(String(format: "%02d", hits.count))
                            .font(Theme.mono(11, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.muted)
                            .accessibilityLabel("\(hits.count) matches")
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 2)

                    ForEach(hits) { hit in
                        NavigationLink(value: hit) {
                            HitRow(hit: hit)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
        }
    }

    private func twoLines(_ top: String, _ bottom: String) -> some View {
        VStack(spacing: 8) {
            Text(top)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.muted)
            Text(bottom)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 48)
        // "no matches / transcripts only · notes aren't indexed" is one
        // thought, and it's the whole screen — one VoiceOver stop, not two.
        .accessibilityElement(children: .combine)
    }

    /// Debounced scan: `.task(id:)` cancels the in-flight sleep on every
    /// keystroke, so only the settled query reaches disk.
    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            hits = []
            scanning = false
            return
        }
        scanning = true
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        // Off the main actor: directory listing + JSON decode per session. A
        // stale detached scan can still finish, but the cancellation check
        // below drops its result.
        let root = state.root
        let found = await Task.detached { TranscriptSearch.scan(root: root, query: q) }.value
        guard !Task.isCancelled else { return }
        hits = found
        scanning = false
    }
}

private struct HitRow: View {
    let hit: TranscriptSearch.Hit

    /// Offset into the recording, in words rather than a mono clock.
    private var spokenStart: String {
        Duration.milliseconds(hit.startMS).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .wide)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(hit.sessionTitle)
                    .font(Theme.face(13, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("[\(Transcript.clock(hit.startMS))]")
                    .font(Theme.mono(10, .semibold))
                    .monospacedDigit()
                    // accent@0.8 was 2.77:1 on surface (light) — under AA even
                    // for large text, and this is 10pt.
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
            }
            snippet
                .font(Theme.face(14))
                .lineSpacing(2)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Title + timestamp + snippet is one search result. Read separately,
        // the timestamp arrives as "bracket one colon two three bracket" and
        // the snippet splits into three fragments at the match boundaries.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(hit.sessionTitle), at \(spokenStart), \(hit.before)\(hit.match)\(hit.after)"
        )
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    /// Concatenated Text so the matched run can carry the accent inline.
    private var snippet: Text {
        Text(hit.before).foregroundStyle(Theme.ink.opacity(0.85))
            + Text(hit.match).foregroundStyle(Theme.accent).bold()
            + Text(hit.after).foregroundStyle(Theme.ink.opacity(0.85))
    }
}

/// Substring search over every session's transcript.json.
enum TranscriptSearch {
    struct Hit: Identifiable, Hashable, Sendable {
        let sessionID: String
        let sessionTitle: String
        /// Index into `Transcript.segments` — what the detail view scrolls to.
        let segment: Int
        let startMS: Int
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
    /// capped at 50 rows, and search shouldn't inherit a display limit.
    /// `SessionSummary.scan` supplies the rows so titles match the home list.
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
                    segment: i,
                    startMS: seg.start_ms,
                    before: before,
                    match: match,
                    after: after
                ))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Window the segment down to ~two lines around the match, eliding the
    /// parts we cut. Grapheme-safe: all offsets go through String.Index.
    static func snippet(
        _ text: String, _ match: Range<String.Index>, lead: Int = 24, trail: Int = 90
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
    /// Runs when the search sheet opens in Debug builds.
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

        let zh = "今天我们讨论定价策略和路线图"
        guard let r2 = zh.range(of: "定价", options: options) else {
            assertionFailure("zh substring match failed")
            return
        }
        let cjk = snippet(zh, r2, lead: 3, trail: 3)
        assert(cjk.match == "定价", "multi-byte match slice broke: \(cjk.match)")
        assert(cjk.before == "…们讨论", "multi-byte lead window broke: \(cjk.before)")
    }
}
#endif
