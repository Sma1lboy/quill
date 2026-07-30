import SwiftUI

/// Developer module — injected only on simulator and DEBUG builds, never in
/// a release build on a real user's phone. High-level knobs for testing:
/// reset state, wipe models/recordings, seed fake sessions, inspect paths.
enum DevSettings {
    static var isDevBuild: Bool {
        #if targetEnvironment(simulator) || DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Every UserDefaults key quill owns. "reset all settings" listed only
    /// two of them, so a reset left the custom notes prompt, the llama
    /// opt-in, and the onboarding flag behind — the one thing a reset is
    /// for. Add new keys here.
    static let allKeys = [
        "quill.languages",
        "quill.model",
        "quill.enhancePrompt",
        "quill.llamaFallback",
        "quill.onboarded",
    ]
}

struct DevSection: View {
    let root: URL
    @State private var confirmWipe = false
    @State private var status = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("DEV")
                    .font(Theme.mono(9, .bold))
                    .tracking(1.5)
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.accent))
                Theme.kicker("debug builds only")
            }

            // Live AI capability probe — answers "what can this device run"
            // without guessing: on-device FM, tagging variant, languages,
            // and the iOS 27 Private Cloud Compute model + quota.
            VStack(alignment: .leading, spacing: 3) {
                ForEach(AICapabilities.probe().lines, id: \.0) { line in
                    HStack(spacing: 8) {
                        Text(line.0)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 110, alignment: .leading)
                        Text(line.1)
                            .font(Theme.mono(10, .medium))
                            // The probe says whether the value is good; the
                            // view doesn't guess from the prose. Substring
                            // matching read "unavailable" as available (it
                            // contains it) and "not supported" as supported,
                            // painting dead capabilities terracotta.
                            .foregroundStyle(AICapabilities.isGood(line.1) ? Theme.accent : Theme.ink)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.inset.opacity(0.5))
            )

            VStack(alignment: .leading, spacing: 2) {
                row("seed 3 fake sessions") {
                    seedFakes()
                    status = "seeded"
                }
                row("delete all whisper models") {
                    for model in ModelCatalog.models {
                        ModelCatalog.delete(model.id)
                    }
                    status = "models deleted — next transcription re-downloads"
                }
                row("reset all settings") {
                    let defaults = UserDefaults.standard
                    for key in DevSettings.allKeys {
                        defaults.removeObject(forKey: key)
                    }
                    status = "settings reset — relaunch to see onboarding"
                }
                row("wipe all recordings", destructive: true) {
                    confirmWipe = true
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.3), lineWidth: 1)
            )

            if !status.isEmpty {
                Text(status)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.accent)
            }

            Text("root: \(root.path)")
                .font(Theme.mono(8))
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .confirmationDialog(
            "Delete every recording and transcript?",
            isPresented: $confirmWipe,
            titleVisibility: .visible
        ) {
            Button("Wipe all recordings", role: .destructive) {
                let fm = FileManager.default
                for url in (try? fm.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil
                )) ?? [] {
                    try? fm.removeItem(at: url)
                }
                status = "recordings wiped"
            }
        }
    }

    private func row(
        _ label: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                Text(label)
                    .font(Theme.mono(11, .medium))
                    .foregroundStyle(destructive ? Theme.error : Theme.ink)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Three fake sessions with real meta/transcript files, for UI work
    /// without recording anything.
    private func seedFakes() {
        let iso = ISO8601DateFormatter()
        let now = Date()
        for (i, text) in [
            "Seeded English session for layout testing.",
            "这是一条用于界面测试的中文假会话。",
            "Sesión falsa en español para probar la interfaz.",
        ].enumerated() {
            let started = now.addingTimeInterval(TimeInterval(-3600 * (i + 1)))
            let name = RecordingSessionNameFormatter.string(from: started, n: i)
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let meta: [String: Any] = [
                "kind": i == 0 ? "note" : "quick",
                "started": iso.string(from: started),
                "ended": iso.string(from: started.addingTimeInterval(300)),
                "duration_seconds": 300,
                "files": ["mic": "mic.caf"],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]) {
                try? data.write(to: dir.appendingPathComponent("meta.json"))
            }
            let transcript = Transcript(
                engine: "dev-seed",
                model: "none",
                created_at: iso.string(from: now),
                segments: [.init(speaker: "me", start_ms: 0, end_ms: 5000, text: text)]
            )
            try? transcript.write(to: dir)
        }
    }
}

/// Session folder names for seeded fakes (kept out of RecordingSession to
/// avoid touching production naming).
private enum RecordingSessionNameFormatter {
    static func string(from date: Date, n: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy.MM.dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date) + "-dev\(n)"
    }
}
