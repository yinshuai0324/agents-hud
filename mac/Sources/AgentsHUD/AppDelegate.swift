import AppKit
import SwiftUI
import Combine

/// Owns the menu-bar status item: left-click toggles the panel popover,
/// right-click (or control-click) opens a 刷新 / 退出 menu. No SwiftUI Scene is
/// used (see main.swift) so the app never shows a stray window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let client = SignalClient.shared
    private var iconObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if runRenderTestIfRequested() { return }
        NSApp.setActivationPolicy(.accessory) // menu-bar only: no Dock icon, no window

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = client.menuBarIcon()
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = NSHostingController(rootView: PanelView(client: client))

        client.start()

        // Keep the menu-bar dot in sync with state changes + blink.
        iconObserver = client.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.statusItem.button?.image = self.client.menuBarIcon()
            }
        }
    }

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        let rightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if rightClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "刷新", action: #selector(refreshAction), keyEquivalent: "")
        refresh.target = self
        let quit = NSMenuItem(title: "退出", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())
        menu.addItem(quit)
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func refreshAction() { client.reconnect() }
    @objc private func quitAction() { NSApplication.shared.terminate(nil) }
}
