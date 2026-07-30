import SwiftUI
import UIKit

/// Folder-level session actions that need more than a view can express:
/// packaging a session for the share sheet.
enum SessionActions {
    /// Zip a session folder for sharing. `NSFileCoordinator`'s `.forUploading`
    /// does the archiving — the zip it hands back is only valid inside the
    /// accessor, so copy it into our own temp box before returning.
    ///
    /// Blocking; call off the main actor.
    static func zip(_ dir: URL) throws -> URL {
        let fm = FileManager.default
        // A fresh box per share means nothing to overwrite and nothing to
        // delete — iOS reaps the temp dir.
        let box = fm.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true
        )
        try fm.createDirectory(at: box, withIntermediateDirectories: true)
        // Named after the folder, so it lands in Files as 2026.07.29-0930.zip.
        let dst = box.appendingPathComponent("\(dir.lastPathComponent).zip")

        var coordError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: dir, options: .forUploading, error: &coordError
        ) { zipped in
            do { try fm.copyItem(at: zipped, to: dst) } catch { copyError = error }
        }
        if let coordError { throw coordError }
        if let copyError { throw copyError }
        return dst
    }
}

/// `UIActivityViewController` for the one case `ShareLink` can't cover: the
/// item doesn't exist until the zip is built, and `ShareLink` needs it at
/// init. Everything else in the app still uses `ShareLink`.
struct ActivityView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The share sheet is presented from state (see `ActivityView`), and
/// `.sheet(item:)` wants Identifiable — URL isn't.
struct SharePayload: Identifiable {
    let id = UUID()
    let url: URL
}

#if DEBUG
extension SessionActions {
    nonisolated(unsafe) private static var checked = false

    /// The one runnable check: title merge semantics (overwrite, no-overwrite,
    /// clear) round-tripped through meta.json via the same reader the home
    /// list and search use, plus a real zip. Runs on the first session opened
    /// in a Debug build.
    ///
    /// ponytail: leaves its temp folder for iOS to reap rather than cleaning up.
    @MainActor
    static func selfCheck() {
        guard !checked else { return }
        checked = true
        let fm = FileManager.default
        let box = fm.temporaryDirectory
            .appendingPathComponent("quill-selfcheck-\(UUID().uuidString)", isDirectory: true)
        let session = box.appendingPathComponent("2026.01.01-0900", isDirectory: true)
        try? fm.createDirectory(at: session, withIntermediateDirectories: true)
        try? Data(#"{"kind":"note","started":"2026-01-01T09:00:00Z"}"#.utf8)
            .write(to: session.appendingPathComponent("meta.json"))

        func storedTitle() -> String? {
            SessionSummary.scan(root: box).first?.contentTitle
        }

        FoundationModelsEnhance.saveTitle("first", in: session, overwrite: true)
        assert(storedTitle() == "first", "rename did not reach meta.json")
        FoundationModelsEnhance.saveTitle("second", in: session, overwrite: true)
        assert(storedTitle() == "second", "overwrite:true failed to replace a title")
        // The enhance pass must still never clobber a title the user set.
        FoundationModelsEnhance.saveTitle("third", in: session)
        assert(storedTitle() == "second", "default saveTitle clobbered a set title")
        FoundationModelsEnhance.saveTitle("", in: session, overwrite: true)
        assert(storedTitle() == nil, "empty title did not fall back to the timestamp")

        // Auto-title scrubbing: what models actually hand back.
        func clean(_ s: String) -> String { FoundationModelsEnhance.clean(s) }
        assert(clean("\"weekly planning · pricing\"") == "weekly planning · pricing", "quotes survived")
        assert(clean("Title: deposit dispute") == "deposit dispute", "label survived")
        assert(clean("landlord call.") == "landlord call", "trailing period survived")
        assert(clean("标题：租金谈判") == "租金谈判", "zh label survived")
        assert(clean("「季度回顾」") == "季度回顾", "cjk quotes survived")
        // A chatty model: explanation on line two, title on line one.
        assert(clean("pricing review\n\nThis title reflects…") == "pricing review", "took more than line one")
        // Length: truncate, never reject (the old guard dropped these).
        let long = clean(String(repeating: "alpha ", count: 20))
        assert(!long.isEmpty, "long title was rejected instead of truncated")
        assert(long.count <= 48, "truncation exceeded budget: \(long.count)")
        assert(!long.hasSuffix(" "), "truncation left trailing space")
        // CJK has no spaces to cut on — must still land inside budget.
        let cjk = clean(String(repeating: "汉", count: 80))
        assert(cjk.count == 48, "cjk truncation missed budget: \(cjk.count)")
        assert(clean("   \n  ").isEmpty, "whitespace-only title should clear")

        guard let archive = try? zip(session) else {
            assertionFailure("zip(_:) threw on a normal session folder")
            return
        }
        assert(archive.pathExtension == "zip", "zip has no .zip extension")
        let size = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        assert(size > 0, "zip is empty")
    }
}
#endif
