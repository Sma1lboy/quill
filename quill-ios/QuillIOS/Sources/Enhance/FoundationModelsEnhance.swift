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

        let imageCount = SessionImages.list(in: dir).count
        let imageNote = imageCount > 0
            ? "\nThe user attached \(imageCount) image(s) (whiteboards/slides not shown to you); add an '## Attachments' line noting they exist."
            : ""

        let session = LanguageModelSession(instructions: Self.prompt + imageNote)

        let response = try await session.respond(to: clipped)
        let notes = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return }

        try Data((notes + "\n").utf8)
            .write(to: dir.appendingPathComponent("notes.md"), options: .atomic)

        // Same session, one more turn: a title. Cheap because the
        // transcript is already in context.
        if let title = try? await session.respond(to: """
            One short title for this note, in its dominant language. \
            3-6 words, lowercase unless a proper noun, no quotes, no period. \
            Output only the title.
            """).content.trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty, title.count <= 60 {
            Self.saveTitle(title, in: dir)
        }
        #endif
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
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
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
