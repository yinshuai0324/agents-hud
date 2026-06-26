import AppKit
import SwiftUI
import Combine

/// Owns the menu-bar status item: left-click toggles the panel popover,
/// right-click (or control-click) opens a 刷新 / 退出 menu. No SwiftUI Scene is
/// used (see main.swift) so the app never shows a stray window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuPanel: MenuBarPanel!
    private let client = SignalClient.shared
    private var iconObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if runRenderIconIfRequested() { return }
        if runRenderTestIfRequested() { return }
        NSApp.setActivationPolicy(.accessory) // menu-bar only: no Dock icon, no window

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateStatusIcon()

        let content = PanelView(client: client)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        menuPanel = MenuBarPanel(content: content)

        client.start()

        // Keep the menu-bar icon in sync with state changes + blink.
        iconObserver = client.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.updateStatusIcon() }
        }
    }

    private func updateStatusIcon() {
        statusItem.button?.image = statusBarImage(dominant: client.dominant, dim: client.blinkDim)
    }

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        let rightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if rightClick {
            showContextMenu()
        } else {
            guard let button = statusItem.button else { return }
            menuPanel.toggle(below: button)
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
