import AppKit
import SwiftUI
import Combine
import UserNotifications

/// A normal windowed desktop app (Dock icon + main window). The menu-bar status
/// item is kept as a bonus quick-glance indicator, but the primary UI is the
/// main window (概览 / 设备 / 设置).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuPanel: MenuBarPanel!
    private let client = SignalClient.shared
    private var iconObserver: AnyCancellable?
    private var serverObserver: AnyCancellable?

    // Shared device/update controllers, owned here so the main window and the
    // menu-bar shortcuts operate on the same instances.
    private let provisioner = BLEProvisioner()
    private let serialProvisioner = SerialProvisioner()
    private let firmwareUpdater = FirmwareUpdater()
    private var mainWindow: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        if runRenderIconIfRequested() { return }
        if runRenderTestIfRequested() { return }

        // Regular app: Dock icon, ⌘Tab, standard menu bar.
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()

        // Menu-bar status item (optional quick glance; the window is primary).
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

        mainWindow = MainWindowController(
            client: client,
            server: ServerController.shared,
            provisioner: provisioner,
            serialProvisioner: serialProvisioner,
            updater: firmwareUpdater
        )

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

        // Show the main window on launch.
        mainWindow.show()
    }

    // Reopen (Dock click / `open` again) refocuses the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow.show()
        return true
    }

    // MARK: - Main menu (built manually — no storyboard)

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 AgentsHUD", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        if UpdaterController.shared.isAvailable {
            let u = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
            u.target = self
            appMenu.addItem(u)
        }
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 AgentsHUD", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 AgentsHUD", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Window menu.
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winItem.submenu = winMenu
        let showMain = NSMenuItem(title: "主窗口", action: #selector(showMainWindow), keyEquivalent: "0")
        showMain.target = self
        winMenu.addItem(showMain)
        winMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = winMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func showMainWindow() { mainWindow.show() }

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
            // Left-click the menu-bar icon shows the quick usage overview popover.
            guard let button = statusItem.button else { return }
            menuPanel.toggle(below: button)
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开主窗口", action: #selector(showMainWindow), keyEquivalent: "")
        open.target = self
        let notify = NSMenuItem(title: "通知", action: #selector(toggleNotifications), keyEquivalent: "")
        notify.target = self
        notify.state = Notifier.shared.enabled ? .on : .off
        let refresh = NSMenuItem(title: "刷新", action: #selector(refreshAction), keyEquivalent: "")
        refresh.target = self
        let quit = NSMenuItem(title: "退出", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(open)
        menu.addItem(notify)
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
    @objc private func checkForUpdates() { UpdaterController.shared.checkForUpdates() }

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

    // Clicking a notification brings up the main window.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in self.mainWindow.show() }
        completionHandler()
    }
}
