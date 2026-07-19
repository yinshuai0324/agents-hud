import Foundation
import Sparkle

/// Sparkle auto-update wiring. The feed URL and EdDSA public key live in
/// Info.plist (SUFeedURL / SUPublicEDKey, written by build-app.sh); the appcast
/// is generated in CI and uploaded to each GitHub Release.
@MainActor
final class UpdaterController {
    static let shared = UpdaterController()

    private var controller: SPUStandardUpdaterController?

    /// Only meaningful inside a real .app bundle — skip under `swift run`
    /// (no Info.plist feed, and Sparkle would log errors).
    func setup() {
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }
}
