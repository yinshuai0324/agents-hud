import AppKit
import SwiftUI

/// Hosts the main window (the app's primary UI). Kept alive by AppDelegate;
/// `show()` re-focuses it (Dock click / reopen) instead of spawning duplicates.
@MainActor
final class MainWindowController {
    private var window: NSWindow?
    private let client: SignalClient
    private let server: ServerController
    private let provisioner: BLEProvisioner
    private let serialProvisioner: SerialProvisioner
    private let updater: FirmwareUpdater

    init(
        client: SignalClient,
        server: ServerController,
        provisioner: BLEProvisioner,
        serialProvisioner: SerialProvisioner,
        updater: FirmwareUpdater
    ) {
        self.client = client
        self.server = server
        self.provisioner = provisioner
        self.serialProvisioner = serialProvisioner
        self.updater = updater
    }

    func show(select section: MainView.Section? = nil) {
        if window == nil {
            let root = MainView(
                client: client,
                server: server,
                provisioner: provisioner,
                serialProvisioner: serialProvisioner,
                updater: updater
            )
            // Set contentView directly (not contentViewController): with
            // fullSizeContentView this fills the *entire* window including the
            // titlebar region, so the NavigationSplitView sidebar extends up
            // behind the traffic lights (the Finder look). contentViewController
            // would clamp the content below the titlebar instead.
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = ""
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.contentView = NSHostingView(rootView: root)
            win.isReleasedWhenClosed = false
            win.appearance = NSAppearance(named: .darkAqua)
            win.center()
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
