@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// First launch. One scrolling page in the DESIGN.md grammar — mono kickers
/// over system-face prose, matte paper, a single accentSoft card for the mic
/// ask so iOS's alert is never the first explanation the user reads.
///
/// ponytail: one page, no wizard, no progress dots, no page-view library —
/// this app's voice would never ceremony a three-step tour.
struct OnboardingView: View {
    let onDone: () -> Void

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var permission: AVAudioApplication.recordPermission = .undetermined
    @State private var asking = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 8) {
                        BracketChip(size: 26)
                        Text("local-first voice notes")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.muted)
                    }
                    .accessibilityElement(children: .combine)

                    block(
                        "what it is",
                        "tap once and talk. every take becomes a folder in Files — audio, transcript, structured notes — that you own and can delete by hand."
                    )
                    block(
                        "on-device",
                        "whisper transcribes on this phone, ~100 languages including chinese. no account, no cloud, no subscription. your audio never leaves the device."
                    )
                    // Model name and size come from the catalog, so this copy
                    // can't drift from the default the app actually downloads.
                    block(
                        "first transcript",
                        "the model downloads once (\(ModelCatalog.selected.label), \(ModelCatalog.selected.size)) with a progress bar, then never again. smaller models live in settings if storage is tight."
                    )

                    micCard
                }
                .padding(.horizontal, 24)
                .padding(.top, 32)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            actions
        }
        .background(Theme.paper.ignoresSafeArea())
        .animation(Theme.spring, value: permission)
        .tint(Theme.accent)
        .task { permission = AVAudioApplication.shared.recordPermission }
        // Returning from Settings with the mic re-enabled should flip the card.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { permission = AVAudioApplication.shared.recordPermission }
        }
    }

    /// The pre-alert card: quill's own reason for wanting the mic, and after a
    /// refusal the exact place to undo it. One branch per permission state —
    /// a granted mic must state the settled fact, never promise an alert that
    /// will never fire.
    private var micCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Theme.kicker("microphone")
            Text(mic.text)
                .font(.subheadline)
                .foregroundStyle(mic.tint)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(mic.wash)
        )
        .accessibilityElement(children: .combine)
    }

    /// accentSoft is the wash for the card that still wants something from you;
    /// a satisfied mic drops to inset (DESIGN.md's quiet banner slot) so it
    /// stops competing with the terracotta button under it.
    private var mic: (text: String, tint: Color, wash: Color) {
        switch permission {
        case .granted:
            return (
                "the mic is on. quill only listens while a take is running.",
                Theme.muted,
                Theme.inset
            )
        case .denied:
            return (
                "the mic is off, so nothing can be recorded. turn it back on in settings › quill › microphone.",
                Theme.error,
                Theme.accentSoft
            )
        default:
            return (
                "recording needs the mic. ios asks next — quill only listens while a take is running.",
                Theme.ink.opacity(0.85),
                Theme.accentSoft
            )
        }
    }

    /// Docked where the record bar lives, so the first tap and every tap after
    /// it land in the same place.
    private var actions: some View {
        VStack(spacing: 4) {
            Button(action: primaryAction) {
                HStack(spacing: 10) {
                    if asking { BrailleSpinner(size: 14, tint: Theme.paper) }
                    Text(primaryLabel)
                        .font(Theme.mono(16, .medium))
                        .foregroundStyle(Theme.paper)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                // minHeight: "allow microphone" at 1.6× scale is taller than
                // 56pt, and a clipped consent button is a dead first launch.
                .frame(minHeight: 56)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.accent)
                )
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(asking)
            .accessibilityLabel(primaryLabel)

            // No dead end: refusing the mic still gets you into the app.
            if permission != .granted {
                Button(action: onDone) {
                    Text("skip for now")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Skip for now")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private var primaryLabel: String {
        switch permission {
        case .granted: return "start"
        case .denied: return "open settings"
        default: return "allow microphone"
        }
    }

    private func primaryAction() {
        switch permission {
        case .granted:
            onDone()
        case .denied:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        default:
            asking = true
            Task { @MainActor in
                let granted = await MicRecorder.requestPermission()
                asking = false
                permission = AVAudioApplication.shared.recordPermission
                // Permission settled — nothing left to explain, don't make
                // them tap "start" to leave a page they've finished reading.
                if granted { onDone() }
            }
        }
    }

    private func block(_ kicker: String, _ prose: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Theme.kicker(kicker)
            Text(prose)
                .font(.subheadline)
                .foregroundStyle(Theme.ink.opacity(0.85))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Gate

extension View {
    /// Shows the first-launch page once, ever. Keeps ContentView to one line.
    func quillOnboarding() -> some View { modifier(OnboardingGate()) }
}

/// ponytail: an @AppStorage bool is the whole "has seen it" layer. Derived
/// straight into the binding — no mirror @State, so the cover is up on the
/// first frame instead of flashing the app behind it.
private struct OnboardingGate: ViewModifier {
    @AppStorage("quill.onboarded") private var onboarded = false

    /// The screenshot harness and the UI tests both drive the app itself, and
    /// a full-screen cover on a fresh install would block every one of them.
    private var pending: Bool {
        let env = ProcessInfo.processInfo.environment
        return !onboarded
            && env["QUILL_PREVIEW"] == nil
            && env["QUILL_SKIP_ONBOARDING"] == nil
    }

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(
            get: { pending },
            set: { if !$0 { onboarded = true } }
        )) {
            OnboardingView { onboarded = true }
        }
    }
}
