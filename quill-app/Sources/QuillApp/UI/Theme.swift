import AppKit
import SwiftUI

// quill follows kobe's design language (kobe/packages/branding/src/colors.ts,
// marketing/kobe-landing-light): warm porcelain paper, espresso ink,
// terracotta as the single brand-defining accent, terminal-native mono
// kickers and bracket chips. quill is a sibling tool, so it inherits the
// family DNA instead of inventing its own.
//
// The popover is solid paper, not system glass — kobe surfaces are matte
// ceramic, and the warm palette dies under a desaturating blur.
enum Theme {
    // kobe light: --paper/--surface/--ink/--muted/--line/--accent
    // kobe dark: bg/bgSoft/fg/muted/border/blue(terracotta)
    private static func dyn(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    static let paper = dyn(
        light: NSColor(red: 0.965, green: 0.953, blue: 0.925, alpha: 1),  // #F6F3EC
        dark: NSColor(red: 0.078, green: 0.078, blue: 0.075, alpha: 1)    // #141413
    )
    static let surface = dyn(
        light: NSColor(red: 0.992, green: 0.988, blue: 0.976, alpha: 1),  // #FDFCF9
        dark: NSColor(red: 0.102, green: 0.098, blue: 0.090, alpha: 1)    // #1A1917
    )
    static let inset = dyn(
        light: NSColor(red: 0.937, green: 0.918, blue: 0.878, alpha: 1),  // #EFEAE0
        dark: NSColor(red: 0.169, green: 0.165, blue: 0.153, alpha: 1)    // #2B2A27
    )
    static let ink = dyn(
        light: NSColor(red: 0.231, green: 0.196, blue: 0.165, alpha: 1),  // #3B322A espresso
        dark: NSColor(red: 0.918, green: 0.906, blue: 0.875, alpha: 1)    // #EAE7DF paper-on-dark
    )
    static let muted = dyn(
        light: NSColor(red: 0.486, green: 0.447, blue: 0.400, alpha: 1),  // #7C7266
        dark: NSColor(red: 0.663, green: 0.639, blue: 0.604, alpha: 1)    // #A9A39A
    )
    static let line = dyn(
        light: NSColor(red: 0.875, green: 0.847, blue: 0.796, alpha: 1),  // #DFD8CB
        dark: NSColor(red: 0.227, green: 0.220, blue: 0.208, alpha: 1)    // #3A3835
    )
    /// Terracotta — the brand accent. Deepened on paper for contrast,
    /// original Claude-port value on dark.
    static let accent = dyn(
        light: NSColor(red: 0.769, green: 0.420, blue: 0.282, alpha: 1),  // #C46B48
        dark: NSColor(red: 0.800, green: 0.471, blue: 0.361, alpha: 1)    // #CC785C
    )
    /// Softened terracotta for washes/hover tints.
    static let accentSoft = dyn(
        light: NSColor(red: 0.769, green: 0.420, blue: 0.282, alpha: 0.10),
        dark: NSColor(red: 0.800, green: 0.471, blue: 0.361, alpha: 0.14)
    )
    /// Error red (kobe error slot) — kept distinct from the accent so
    /// terracotta never has to mean "problem".
    static let error = dyn(
        light: NSColor(red: 0.714, green: 0.341, blue: 0.259, alpha: 1),  // #B65742
        dark: NSColor(red: 0.831, green: 0.459, blue: 0.388, alpha: 1)    // #D47563
    )

    static let radius: CGFloat = 8

    // Terminal-native type: mono carries labels, numbers, and kickers
    // (kobe's navbar/kicker treatment); the system face carries prose.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// Uppercase mono kicker with tracked-out letters — kobe's section label.
    static func kicker(_ text: String) -> some View {
        Text(text.uppercased())
            .font(mono(10, .medium))
            .tracking(1.2)
            .foregroundStyle(muted)
    }
}
