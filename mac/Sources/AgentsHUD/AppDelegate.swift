import AppKit
import SwiftUI
import Combine
import UserNotifications

/// Owns the menu-bar status item: left-click toggles the panel popover,
/// right-click (or control-click) opens a 刷新 / 退出 menu. No SwiftUI Scene is
/// used (see main.swift) so the app never shows a stray window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuPanel: MenuBarPanel!
    private let client = SignalClient.shared
    private var iconObserver: AnyCancellable?
    private var serverObserver: AnyCancellable?
    private let pairingWindow = PairingWindowController()
    private let devicesWindow = DevicesWindowController()

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

        // Session-state notifications (轮到你 / 审批 / 出错). Only from a real
        // bundle — skip in `swift run` so it doesn't crash.
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            Notifier.shared.setup()
        }

        // Embedded server first (data source), then the UI's local WS client.
        ServerController.shared.start()
        client.start()
        UpdaterController.shared.setup()

        // Surface a port conflict (old brew service still running) once.
        serverObserver = ServerController.shared.$status.sink { [weak self] status in
            guard case .portConflict = status else { return }
            Task { @MainActor in self?.showPortConflictAlert() }
        }

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
        let notify = NSMenuItem(title: "通知", action: #selector(toggleNotifications), keyEquivalent: "")
        notify.target = self
        notify.state = Notifier.shared.enabled ? .on : .off
        let pair = NSMenuItem(title: "连接手机…", action: #selector(showPairingQR), keyEquivalent: "")
        pair.target = self
        let devices = NSMenuItem(title: "设备…", action: #selector(showDevices), keyEquivalent: "")
        devices.target = self
        let hooks = NSMenuItem(
            title: ServerController.shared.hooksInstalled ? "重新安装 Claude Code 钩子" : "安装 Claude Code 钩子",
            action: #selector(installHooksAction),
            keyEquivalent: ""
        )
        hooks.target = self
        let refresh = NSMenuItem(title: "刷新", action: #selector(refreshAction), keyEquivalent: "")
        refresh.target = self
        let quit = NSMenuItem(title: "退出", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(notify)
        menu.addItem(pair)
        menu.addItem(devices)
        menu.addItem(hooks)
        if UpdaterController.shared.isAvailable {
            let update = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
            update.target = self
            menu.addItem(update)
        }
        menu.addItem(.separator())
        menu.addItem(refresh)
        menu.addItem(quit)
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func toggleNotifications() { Notifier.shared.enabled.toggle() }
    @objc private func refreshAction() { client.reconnect() }
    @objc private func quitAction() { NSApplication.shared.terminate(nil) }

    @objc private func showPairingQR() {
        pairingWindow.show(payload: ServerController.shared.pairingPayload)
    }

    @objc private func checkForUpdates() {
        UpdaterController.shared.checkForUpdates()
    }

    @objc private func showDevices() {
        devicesWindow.show(server: ServerController.shared)
    }

    @objc private func installHooksAction() {
        let alert = NSAlert()
        do {
            let result = try ServerController.shared.installHooks()
            alert.messageText = "钩子已安装"
            var info = "已写入 \(result.settingsPath)\n重启运行中的 Claude Code 会话后生效。"
            if let warning = result.statuslineWarning { info += "\n\n\(warning)" }
            alert.informativeText = info
        } catch {
            alert.messageText = "钩子安装失败"
            alert.informativeText = String(describing: error)
            alert.alertStyle = .warning
        }
        alert.runModal()
    }

    private func showPortConflictAlert() {
        let alert = NSAlert()
        alert.messageText = "端口被占用"
        alert.informativeText = ServerController.brewConflictHint
        alert.addButton(withTitle: "重试")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn {
            ServerController.shared.retryAfterConflict()
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    // Show the banner + play sound even when our app happens to be active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Clicking a notification opens the panel.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            if let button = self.statusItem.button { self.menuPanel.show(below: button) }
        }
        completionHandler()
    }
}
