import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device ~3B system model (FoundationModels, iOS 26+) turning a
/// raw transcript into structured markdown notes. Zero download, zero
/// network — the same "nothing leaves the phone" contract as WhisperKit.
/// Light reconstruction (summary/points/actions) is exactly the size of
/// task this model is built for; if quality tops out, the EnhanceService
/// seam swaps in a server backend later.
struct FoundationModelsEnhance: EnhanceService {
    /// The default structuring instructions — shown and editable in
    /// settings ("quill.enhancePrompt" overrides).
    static let defaultPrompt = """
        You turn raw voice-note transcripts into clean, readable markdown \
        notes, in the transcript's dominant language. Output only markdown.

        Structure: start with one short summary paragraph (no heading). \
        Then the notes as bullet points grouped under a few ## headings \
        named after the actual topics discussed — never generic labels \
        like "Key points". Nest sub-bullets progressively: a main point, \
        then its supporting details, examples, or quotes indented beneath.

        Action items: judge the content type first. A talk, lecture, \
        interview, or personal memo has no action items — do not invent \
        any. Only if this is a working meeting with real commitments \
        (someone agreed to do something), end with ## Action items as \
        - [ ] bullets naming who does what. When in doubt, leave it out.

        Never include meta-instructions or word counts in headings.
        """

    static var prompt: String {
        let custom = UserDefaults.standard.string(forKey: "quill.enhancePrompt")
        return (custom?.isEmpty == false ? custom! : defaultPrompt)
    }

    /// Auto-title instructions, shared by both enhance backends so the two
    /// paths can't drift into different title voices. Length is stated here
    /// and enforced in `saveTitle` — models treat word counts as a suggestion.
    static let titlePrompt = """
        Give one title for this note, in its dominant language. Two to five \
        words. Lowercase unless a proper noun. Name the actual subjects, \
        joined by " · " when there are two — like "weekly planning · pricing" \
        or "landlord call · deposit". No quotes, no punctuation at the end, \
        no label, no explanation. Output only the title.
        """

    /// Suffix appended to the instructions when the session has images: the
    /// text Vision read off them, else just a note that they exist. Shared by
    /// both enhance backends so the two can't drift.
    static func imageContext(_ dir: URL) async -> String {
        let count = SessionImages.list(in: dir).count
        guard count > 0 else { return "" }
        let existence = "\nThe user attached \(count) image(s) (whiteboards/slides); "
            + "add an '## Attachments' line noting they exist."
        guard let text = await SessionOCR.text(in: dir) else { return existence }
        return existence + SessionOCR.promptBlock(text)
    }

    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    /// Human-readable reason when unavailable, for surfacing in the UI.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "enable Apple Intelligence in Settings to generate notes"
            case .unavailable(.modelNotReady):
                return "Apple Intelligence model still downloading — try again later"
            case .unavailable(.deviceNotEligible):
                return "this device can't run Apple Intelligence"
            case .unavailable:
                return "on-device model unavailable"
            }
        }
        #endif
        return "requires iOS 26"
    }

    func enhance(session dir: URL) async throws {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return }

        let transcriptURL = dir.appendingPathComponent("transcript.md")
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
              !transcript.isEmpty else { return }

        // The model's context is limited (~4k tokens) — clip long meetings
        // to the first ~8k chars (leave headroom: overshooting the window
        // throws GenerationError, and a 20-min meeting easily exceeds it).
        // ponytail: chunked map-reduce when hour-long sessions matter.
        let clipped = String(transcript.prefix(8_000))

        let session = LanguageModelSession(
            instructions: Self.prompt + (await Self.imageContext(dir))
        )

        let response = try await session.respond(to: clipped)
        let notes = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return }

        try Data((notes + "\n").utf8)
            .write(to: dir.appendingPathComponent("notes.md"), options: .atomic)

        // Same session, one more turn: a title. Cheap because the transcript
        // is already in context. Best-effort — `try?` keeps notes.md when the
        // title turn fails, and saveTitle scrubs whatever comes back.
        if let title = try? await session.respond(to: Self.titlePrompt).content {
            Self.saveTitle(title, in: dir)
        }
        #endif
    }

    /// Scrub a model-written title down to a row label. Models ignore length
    /// and voice instructions often enough that the prompt can't be the only
    /// defense: they wrap in quotes, end with a period, prefix "Title:", and
    /// occasionally answer in a sentence. First line only, since a chatty
    /// model puts its explanation on line two.
    ///
    /// ponytail: word-boundary truncation at 48 chars, not tokens or display
    /// width — the row already lineLimit(1)s, this just keeps meta.json sane.
    static func clean(_ raw: String) -> String {
        var title = raw
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)

        // "Title: weekly planning" / "标题：..." — drop a leading label.
        for label in ["title:", "标题:", "标题："] where title.lowercased().hasPrefix(label) {
            title = String(title.dropFirst(label.count))
                .trimmingCharacters(in: .whitespaces)
        }
        // Surrounding quotes, straight or curly, ASCII or CJK.
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’「」『』 "))
        // Trailing sentence punctuation; a "?" is meaningful, a "." never is.
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: ".。,，;；:：!！ "))

        guard title.count > 48 else { return title }
        // Cut on the last space inside the budget so we don't sever a word;
        // CJK has no spaces, so it falls through to the hard cut.
        let budget = title.prefix(48)
        if let space = budget.lastIndex(of: " "), budget.distance(from: budget.startIndex, to: space) > 24 {
            return String(budget[budget.startIndex..<space])
        }
        return String(budget).trimmingCharacters(in: .whitespaces)
    }

    /// Merge a title into meta.json — the single source `SessionSummary.scan`
    /// reads, so the home list and search both pick it up. The generated
    /// title never overwrites one already there; a user rename passes
    /// `overwrite: true`. An empty title clears the key, falling the row back
    /// to its timestamp.
    ///
    /// `.atomic` writes via temp + rename, so a crash mid-write keeps the old
    /// meta.json rather than truncating it.
    static func saveTitle(_ title: String, in dir: URL, overwrite: Bool = false) {
        let url = dir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: url),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        guard overwrite || (json["title"] as? String)?.isEmpty != false else { return }
        let trimmed = clean(title)
        if trimmed.isEmpty {
            json.removeValue(forKey: "title")
        } else {
            json["title"] = trimmed
        }
        if let out = try? JSONSerialization.data(
            withJSONObject: json, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? out.write(to: url, options: .atomic)
        }
    }
}
