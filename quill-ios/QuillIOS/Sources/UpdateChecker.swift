import Foundation
import SwiftUI

/// Sideload-era update detection: each deploy publishes a tiny manifest to
/// the brand-studio share worker (stable URL); the app fetches it on launch
/// and compares build numbers. Newer build → banner in settings/home.
/// When distribution moves to TestFlight this whole file retires.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Manifest: Decodable {
        let version: String
        let build: String
        let notes: String?
    }

    static let manifestURL = URL(string: "https://brand-studio.sma1lboy.me/s/quill-ios-version")!

    @Published private(set) var available: Manifest?

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
    }
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// Pull the manifest out of the share page. The page is a full HTML
    /// document whose share-bar CSS contains `{...}` blocks, so the *first*
    /// brace is a style rule, never the manifest — the manifest is appended
    /// after the closing markup, making the trailing `{...}` the right slice.
    static func extractManifest(from html: String) -> Manifest? {
        guard let start = html.lastIndex(of: "{"),
              let end = html.lastIndex(of: "}"),
              start < end
        else { return nil }
        return try? JSONDecoder().decode(
            Manifest.self, from: Data(html[start...end].utf8)
        )
    }

    /// Build numbers are integers (`18174101`), so compare them as integers —
    /// a string compare would rank "9" above "18174101". An unparseable
    /// manifest build stays at 0 and therefore never prompts.
    static func isNewer(_ manifestBuild: String, than current: String) -> Bool {
        (Int(manifestBuild) ?? 0) > (Int(current) ?? 0)
    }

    func check() {
        #if DEBUG
        Self._selfCheck()
        #endif
        Task {
            // Explicit timeout: a hung server must not leave the task parked
            // on the default 60s system timeout.
            var request = URLRequest(url: Self.manifestURL)
            request.timeoutInterval = 10
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data, encoding: .utf8),
                  let manifest = Self.extractManifest(from: html)
            else { return }

            available = Self.isNewer(manifest.build, than: Self.currentBuild) ? manifest : nil
        }
    }

    #if DEBUG
    /// Self-check for the two things that silently broke this feature: the
    /// brace slice (CSS braces come first in the real page) and integer
    /// build comparison (string compare gets it backwards).
    static func _selfCheck() {
        let page = """
        <style>#bs{position:fixed;top:0}</style><div>hi</div>
        {"version":"0.2.0","build":"18174200","notes":"x"}
        """
        let m = extractManifest(from: page)
        assert(m?.build == "18174200", "manifest must come from the trailing brace block, not the CSS rule")
        assert(isNewer("18174200", than: "18174101"))
        assert(!isNewer("18174101", than: "18174101"))
        assert(isNewer("9", than: "8"))
        // The bug a string compare would introduce, in both directions.
        assert(!isNewer("9", than: "18174101"), "\"9\" > \"18174101\" as strings; must be false numerically")
        assert(isNewer("18174101", than: "9"))
        assert(!isNewer("not-a-number", than: "18174101"))
        assert(extractManifest(from: "<style>a{b:c}</style>") == nil)
    }
    #endif
}

/// Terracotta pill shown when a newer build exists on the Mac.
struct UpdateBanner: View {
    let manifest: UpdateChecker.Manifest

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            Text("update available · \(manifest.version) (\(manifest.build))")
                .font(Theme.mono(11, .medium))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 0)
            Text("plug in to install")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.accentSoft)
        )
    }
}
