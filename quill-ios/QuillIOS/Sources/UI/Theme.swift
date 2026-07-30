import SwiftUI
import UIKit

// quill design language — see /DESIGN.md (truth source, locked round 3).
// Palette inherited from kobe/packages/branding/src/colors.ts: porcelain
// paper, espresso ink, terracotta accent. Matte surfaces, never glass.
enum Theme {
    private static func dyn(_ light: UIColor, _ dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    static let paper = dyn(
        UIColor(red: 0.965, green: 0.953, blue: 0.925, alpha: 1),  // #F6F3EC
        UIColor(red: 0.078, green: 0.078, blue: 0.075, alpha: 1)   // #141413
    )
    static let surface = dyn(
        UIColor(red: 0.992, green: 0.988, blue: 0.976, alpha: 1),  // #FDFCF9
        UIColor(red: 0.102, green: 0.098, blue: 0.090, alpha: 1)   // #1A1917
    )
    static let inset = dyn(
        UIColor(red: 0.937, green: 0.918, blue: 0.878, alpha: 1),  // #EFEAE0
        UIColor(red: 0.169, green: 0.165, blue: 0.153, alpha: 1)   // #2B2A27
    )
    static let ink = dyn(
        UIColor(red: 0.231, green: 0.196, blue: 0.165, alpha: 1),  // #3B322A
        UIColor(red: 0.918, green: 0.906, blue: 0.875, alpha: 1)   // #EAE7DF
    )
    static let muted = dyn(
        UIColor(red: 0.486, green: 0.447, blue: 0.400, alpha: 1),  // #7C7266
        UIColor(red: 0.663, green: 0.639, blue: 0.604, alpha: 1)   // #A9A39A
    )
    static let line = dyn(
        UIColor(red: 0.875, green: 0.847, blue: 0.796, alpha: 1),  // #DFD8CB
        UIColor(red: 0.227, green: 0.220, blue: 0.208, alpha: 1)   // #3A3835
    )
    static let accent = dyn(
        UIColor(red: 0.769, green: 0.420, blue: 0.282, alpha: 1),  // #C46B48
        UIColor(red: 0.800, green: 0.471, blue: 0.361, alpha: 1)   // #CC785C
    )
    static let accentSoft = dyn(
        UIColor(red: 0.769, green: 0.420, blue: 0.282, alpha: 0.10),
        UIColor(red: 0.800, green: 0.471, blue: 0.361, alpha: 0.14)
    )
    static let error = dyn(
        UIColor(red: 0.714, green: 0.341, blue: 0.259, alpha: 1),  // #B65742
        UIColor(red: 0.831, green: 0.459, blue: 0.388, alpha: 1)   // #D47563
    )

    static let radius: CGFloat = 8

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func kicker(_ text: String) -> some View {
        Text(text.uppercased())
            .font(mono(11, .medium))
            .tracking(1.2)
            .foregroundStyle(muted)
    }

    /// Critically damped house spring; fades under Reduce Motion.
    @MainActor
    static var spring: Animation {
        UIAccessibility.isReduceMotionEnabled
            ? .easeOut(duration: 0.15)
            : .spring(response: 0.35, dampingFraction: 1.0)
    }
}

/// `[ quill ]` — terracotta brackets, ink word. The kobe bracket-chip grammar.
struct BracketChip: View {
    var size: CGFloat = 17

    var body: some View {
        HStack(spacing: 0) {
            Text("[").foregroundStyle(Theme.accent)
            Text(" quill ").foregroundStyle(Theme.ink)
            Text("]").foregroundStyle(Theme.accent)
        }
        .font(Theme.mono(size, .bold))
    }
}

/// Instant press feedback: scale 0.97 on touch-down.
struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 1.0), value: configuration.isPressed)
    }
}

/// kobe's terminal braille spinner (engine spinner-frames.ts), rendered in
/// mono at 12.5 fps — the pixel-dot loading glyph used everywhere quill
/// shows indeterminate work. Degrades to a static glyph under Reduce Motion.
struct BrailleSpinner: View {
    var size: CGFloat = 12
    var tint: Color = Theme.accent

    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    @State private var frame = 0

    var body: some View {
        Text(Self.frames[frame])
            .font(Theme.mono(size, .semibold))
            .foregroundStyle(tint)
            .monospacedDigit()
            .accessibilityLabel("loading")
            .task {
                guard !UIAccessibility.isReduceMotionEnabled else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(80))
                    frame = (frame + 1) % Self.frames.count
                }
            }
    }
}

/// Five desynced capsules breathing with the live level (weights per DESIGN.md).
struct Waveform: View {
    let level: Float
    let tint: Color
    var maxHeight: CGFloat = 20
    private static let weights: [CGFloat] = [0.5, 0.9, 1.0, 0.7, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<Self.weights.count, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.9))
                    .frame(
                        width: 3,
                        height: 3 + CGFloat(min(1, sqrt(level))) * maxHeight * Self.weights[i]
                    )
                    .animation(.linear(duration: 1.0 / 15.0), value: level)
            }
        }
        .accessibilityHidden(true)
    }
}
