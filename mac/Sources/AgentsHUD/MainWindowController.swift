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
    private let navigation = MainNavigation()

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
        if let section { navigation.selection = section }
        if window == nil {
            let root = MainView(
                client: client,
                server: server,
                provisioner: provisioner,
                serialProvisioner: serialProvisioner,
                updater: updater,
                navigation: navigation
            )
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "Agents HUD"
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.titlebarSeparatorStyle = .none
            win.isMovableByWindowBackground = true
            win.isOpaque = false
            win.backgroundColor = .clear
            win.contentViewController = NSHostingController(rootView: root)
            // Tahoe's full-size transparent titlebar places the traffic lights
            // very close to the top edge. Move the native controls down as a
            // group while preserving their standard spacing and behavior.
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = win.standardWindowButton(kind) {
                    var frame = button.frame
                    frame.origin.y -= 6
                    button.setFrameOrigin(frame.origin)
                }
            }
            win.isReleasedWhenClosed = false
            win.minSize = NSSize(width: 680, height: 460)
            win.center()
            window = win
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
