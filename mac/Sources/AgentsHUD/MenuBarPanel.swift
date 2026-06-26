import AppKit
import SwiftUI

/// A borderless floating panel anchored under the menu-bar status item. Replaces
/// NSPopover so there's no arrow, no system border / aliasing — the rounded
/// frosted look is fully ours. Sizes to the SwiftUI content and dismisses when
/// the user clicks outside the app.
@MainActor
final class MenuBarPanel {
    private let panel: NSPanel
    private let hostingView: NSView
    private var clickMonitor: Any?

    init(content: some View) {
        hostingView = NSHostingView(rootView: AnyView(content))
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
    }

    var isVisible: Bool { panel.isVisible }

    func toggle(below button: NSStatusBarButton) {
        if panel.isVisible { hide() } else { show(below: button) }
    }

    func show(below button: NSStatusBarButton) {
        panel.setContentSize(hostingView.fittingSize)
        let size = panel.frame.size

        guard let win = button.window else { return }
        let anchor = win.convertToScreen(button.convert(button.bounds, to: nil))
        var x = anchor.midX - size.width / 2
        let y = anchor.minY - size.height - 6 // a small gap below the menu bar
        if let visible = (win.screen ?? NSScreen.main)?.visibleFrame {
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        panel.invalidateShadow()

        // Dismiss on any click outside our app (clicks on our status item are
        // delivered locally and handled by its action, so they don't fire here).
        removeMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        removeMonitor()
        panel.orderOut(nil)
    }

    private func removeMonitor() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }
}
