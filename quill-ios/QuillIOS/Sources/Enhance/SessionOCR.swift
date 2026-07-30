import Foundation
import UIKit
import Vision

/// Text pulled off the session's attached images with Vision OCR, cached in
/// the session folder as `ocr.json`. A photographed whiteboard or slide is
/// the high-value case: the words on it belong in the notes, and Vision does
/// this natively on-device — no model download, no network, same contract as
/// the rest of the pipeline.
///
/// The result feeds the enhance prompt as *context*, never straight into
/// notes.md: raw OCR is unpunctuated and line-broken mid-sentence, so a dump
/// of it reads worse than no feature at all.
enum SessionOCR {
    /// filename → recognized text. An empty string means "we looked and found
    /// nothing" — cached deliberately, so a blank or unreadable photo is
    /// attempted exactly once instead of on every enhance re-run and launch.
    private static let cacheName = "ocr.json"

    /// Recognized text for every attached image, newline-joined, or nil when
    /// there's nothing usable. Cached results are reused; only images missing
    /// from the cache are scanned.
    ///
    /// Runs Vision off the calling actor — accurate-level OCR on a few 12MP
    /// photos is seconds of CPU, and the caller is the transcription actor.
    static func text(in dir: URL) async -> String? {
        #if DEBUG
        selfCheck()
        #endif
        let images = SessionImages.list(in: dir)
        guard !images.isEmpty else { return nil }

        var cache = readCache(in: dir)
        let missing = images.filter { cache[$0.lastPathComponent] == nil }
        if !missing.isEmpty {
            let scanned = await Task.detached(priority: .utility) {
                missing.reduce(into: [String: String]()) {
                    $0[$1.lastPathComponent] = recognize($1)
                }
            }.value
            cache.merge(scanned) { _, new in new }
            writeCache(cache, in: dir)
        }

        // Keep the images' own order, drop the ones that yielded nothing.
        let found = images
            .compactMap { cache[$0.lastPathComponent] }
            .filter { !$0.isEmpty }
        return found.isEmpty ? nil : found.joined(separator: "\n")
    }

    /// One image → its text, or "" when unreadable or textless. Never throws:
    /// this whole feature is a nice-to-have and must not fail the notes pass.
    private static func recognize(_ url: URL) -> String {
        guard let image = UIImage(contentsOfFile: url.path)?.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        // Accurate over .fast: a whiteboard photo is the point, and this runs
        // once per image ever thanks to the cache.
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // ponytail: no recognitionLanguages set — Vision's default covers
        // en + the system languages. Set it from the whisper language
        // allow-set if CJK whiteboards read badly.
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Cache (session folder, same JSON grammar as meta.json)

    private static func readCache(in dir: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(cacheName)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return json
    }

    private static func writeCache(_ cache: [String: String], in dir: URL) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: cache, options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: dir.appendingPathComponent(cacheName), options: .atomic)
    }

    /// The context block handed to the enhance prompt. Clipped so images can
    /// never crowd the transcript out of the model's ~4k-token window.
    static func promptBlock(_ text: String, budget: Int = 1_500) -> String {
        """

        --- text visible in the user's attached images (whiteboards, slides, \
        notes). It is raw OCR: unpunctuated, possibly garbled, line order \
        unreliable. Use it to correct spellings of names and terms you heard \
        in the transcript, and to fill in what was pointed at but not said. \
        Never quote it verbatim and never list it as its own section. ---
        \(text.prefix(budget))
        """
    }

    #if DEBUG
    /// The two things here that can silently rot: the clip budget, and
    /// "cached empty means don't retry".
    static func selfCheck() {
        // The clip, not the total: asserting a total length would fail on the
        // next wording edit rather than on a real regression.
        let overhead = promptBlock("").count
        assert(promptBlock(String(repeating: "x", count: 5_000)).count == overhead + 1_500)
        assert(promptBlock("board says foo").contains("board says foo"))
        // An image cached as "" is present in the cache, so it is never
        // re-scanned — the whole point of storing failures.
        let cache = ["img-001.jpg": ""]
        assert(cache["img-001.jpg"] != nil)
        assert(cache["img-001.jpg"]?.isEmpty == true)
    }
    #endif
}
