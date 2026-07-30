import AppKit
import Combine
import SwiftUI

/// Menu-bar status item + NSPopover hosting the SwiftUI interface. The
/// feather icon turns red while recording; clicking toggles the popover
/// (transient — it closes when focus leaves, spatially anchored to the icon).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let state: AppState
    private var cancellables: Set<AnyCancellable> = []

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(state: state)
        )
        popover.delegate = self

        if let button = statusItem.button {
            button.image = Self.idleImage
            button.action = #selector(togglePopover)
            button.target = self
        }

        // The icon is this app's main surface — with the popover closed it's the
        // only thing telling you a recording is live. Swapping the image (not
        // `contentTintColor`, which a template image ignores: the menu bar
        // recolors template art itself and the tint never reaches the pixels)
        // also keeps the elapsed time visible without opening anything.
        state.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                guard let button = self?.statusItem.button else { return }
                if case .recording = phase {
                    button.image = Self.recordingImage
                } else {
                    button.image = Self.idleImage
                    button.title = ""
                }
            }
            .store(in: &cancellables)

        // Elapsed time beside the icon, mono and monospaced-digit so the width
        // doesn't jitter (DESIGN.md: numbers are always monospacedDigit).
        state.$elapsed
            .receive(on: RunLoop.main)
            .sink { [weak self] elapsed in
                guard let button = self?.statusItem.button else { return }
                guard state.isRecording else { return }
                button.attributedTitle = NSAttributedString(
                    string: " \(AppState.format(elapsed))",
                    attributes: [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                        .foregroundColor: Self.accent,
                    ]
                )
            }
            .store(in: &cancellables)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            state.refreshSessions()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            // Transient popovers need the app active to receive key events.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // Inlined Lucide feather SVG — single binary, no resource bundle.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    /// Terracotta (DESIGN.md accent, light value) — the recording state's color
    /// everywhere else in quill, so the menu bar agrees with the popover.
    private static let accent = NSColor(red: 0.769, green: 0.420, blue: 0.282, alpha: 1)

    /// Template art: the menu bar recolors it for light/dark and for the
    /// highlighted state.
    private static let idleImage: NSImage? = {
        let image = featherImage()
        image?.isTemplate = true
        return image
    }()

    /// Accent baked into the pixels. A template image can't carry a custom
    /// color, so recording needs its own non-template copy.
    private static let recordingImage: NSImage? = {
        guard let base = featherImage() else { return nil }
        let tinted = NSImage(size: base.size)
        tinted.lockFocus()
        base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        accent.set()
        NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }()

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    #if DEBUG
    /// The tint must actually reach the pixels — `contentTintColor` on a
    /// template image silently doesn't, which is the bug this replaced.
    static func selfCheck() {
        func coloredPixels(_ image: NSImage?) -> Int {
            guard let tiff = image?.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return -1 }
            var colored = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.3 else { continue }
                    if abs(c.redComponent - c.greenComponent) > 0.12
                        || abs(c.greenComponent - c.blueComponent) > 0.12 { colored += 1 }
                }
            }
            return colored
        }
        assert(coloredPixels(recordingImage) > 0, "recording icon renders gray — tint lost")
        assert(idleImage?.isTemplate == true, "idle icon must stay template art")
        assert(recordingImage?.isTemplate == false, "tinted icon must not be template")
    }
    #endif
}
