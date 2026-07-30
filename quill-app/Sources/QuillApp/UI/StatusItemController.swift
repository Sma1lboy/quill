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
            let image = Self.featherImage()
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Reflect recording state on the icon so it reads at a glance even
        // with the popover closed.
        state.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] phase in
                let recording = { if case .recording = phase { return true }; return false }()
                self?.statusItem.button?.contentTintColor = recording ? .systemRed : nil
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

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
