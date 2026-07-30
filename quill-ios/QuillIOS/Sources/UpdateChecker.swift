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

    func check() {
        Task {
            guard let (data, _) = try? await URLSession.shared.data(from: Self.manifestURL),
                  let html = String(data: data, encoding: .utf8),
                  // Manifest is embedded in the share page as the first {...} block.
                  let start = html.firstIndex(of: "{"),
                  let end = html[start...].firstIndex(of: "}")
            else { return }
            let json = String(html[start...end])
            guard let manifest = try? JSONDecoder().decode(
                Manifest.self, from: Data(json.utf8)
            ) else { return }

            // Numeric compare when possible; string compare as fallback.
            let newer = (Int(manifest.build) ?? 0) > (Int(Self.currentBuild) ?? 0)
            available = newer ? manifest : nil
        }
    }
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
