import AppKit
import SwiftUI

/// Screenshot harness: QUILL_PREVIEW=idle|recording renders the popover
/// content in a borderless floating window so `screencapture -l` can grab it
/// without poking the real status item. Not part of the normal app flow.
@MainActor
enum PreviewHarness {
    static func run(root: URL, mode: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // QUILL_APPEARANCE=light|dark pins the appearance for screenshots.
        if let wanted = ProcessInfo.processInfo.environment["QUILL_APPEARANCE"] {
            app.appearance = NSAppearance(named: wanted == "dark" ? .darkAqua : .aqua)
        }

        let state = AppState(root: root)
        if mode == "recording" {
            state.enterPreviewRecording()
        }

        // The view carries its own solid paper background (kobe language —
        // matte, not glass); the harness just rounds the corners.
        let host = NSHostingController(rootView:
            PopoverView(state: state)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.borderless]
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.setContentSize(host.view.fittingSize)
        window.center()
        window.makeKeyAndOrderFront(nil)

        FileHandle.standardError.write(Data(
            "preview window id \(window.windowNumber) mode \(mode)\n".utf8
        ))
        app.run()
    }
}

/// The NSPopover chrome normally provides the material; the preview window
/// recreates it so screenshots match what the popover looks like.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
