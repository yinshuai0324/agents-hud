import Foundation
import AppKit
import AgentsHUDCore

/// Owns the embedded server: builds the engine + HTTP/WS server + Bonjour and
/// starts them at app launch. Replaces the external Node `agents-hud serve`.
@MainActor
final class ServerController: ObservableObject {
    static let shared = ServerController()

    enum Status: Equatable {
        case stopped
        case starting
        case running(port: Int)
        /// Port already taken — most likely the old brew-installed Node server.
        case portConflict(Int)
        case failed(String)
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var devices: [DeviceInfo] = []
    @Published private(set) var enabledUsageProviders: Set<String>

    let config: Config
    let deviceGateway = DeviceGateway()
    private var engine: StateEngine?
    private var server: HUDServer?
    private let bonjour = BonjourAdvertiser()
    private var devicesOff: (() -> Void)?

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    private init() {
        config = Config.load()
        enabledUsageProviders = Self.loadEnabledUsageProviders()
    }

    var pairingPayload: PairingPayload {
        Pairing.build(port: config.port, token: config.authToken)
    }

    func start() {
        guard status == .stopped else { return }
        status = .starting
        let cfg = config

        let engine = StateEngine(
            cfg: cfg,
            providers: [
                ClaudeProvider(cfg: cfg),
                CodexProvider(cfg: cfg),
                GeminiProvider(cfg: cfg),
            ],
            enabledProviders: enabledUsageProviders
        )
        self.engine = engine
        let server = HUDServer(
            cfg: cfg,
            engine: engine,
            deviceGateway: deviceGateway,
            serverVersion: Self.appVersion
        )
        self.server = server

        devicesOff = deviceGateway.onDevicesChanged { [weak self] list in
            Task { @MainActor in self?.devices = list }
        }

        Task {
            await engine.start()
            do {
                try await server.start()
                // The HTTP/WS listener is the service readiness boundary.
                // Bonjour is an auxiliary discovery advertisement and may
                // wait on the system mDNS daemon; it must not leave the UI
                // stuck in `.starting` after the server is already healthy.
                self.status = .running(port: cfg.port)
                // NetService.publish() can block the main thread indefinitely
                // when the local mDNS daemon is unavailable. ServerController
                // is @MainActor, so that freezes every SwiftUI click and even
                // prevents the `.running` state from painting. Keep the core
                // service responsive; Bonjour discovery will be restored with
                // a dedicated run-loop worker rather than running inline here.
            } catch {
                engine.stop()
                self.engine = nil
                self.server = nil
                if Self.isPortInUse(cfg.port) {
                    self.status = .portConflict(cfg.port)
                } else {
                    self.status = .failed(String(describing: error))
                }
            }
        }
    }

    func stop() {
        bonjour.stop()
        devicesOff?()
        devicesOff = nil
        engine?.stop()
        engine = nil
        let server = self.server
        self.server = nil
        Task { await server?.stop() }
        status = .stopped
    }

    /// Installs the hook bridge from the app bundle. Destination paths match
    /// the old Node installer, so existing settings.json entries keep working.
    func installHooks() throws -> HooksInstaller.Result {
        // SwiftPM resources: Bundle.module resolves both under `swift run`
        // (bundle next to the binary) and inside the assembled .app.
        guard let dir = Bundle.module.url(forResource: "hooks", withExtension: nil) else {
            throw HooksInstaller.InstallError.missingScript("app bundle hooks/")
        }
        return try HooksInstaller.install(cfg: config, scriptsSourceDir: dir)
    }

    func uninstallHooks() throws {
        try HooksInstaller.uninstall(cfg: config)
    }

    var hooksInstalled: Bool {
        HooksInstaller.isInstalled(cfg: config)
    }

    // MARK: Usage sources

    private static let usageProviderOrder = ["claude", "codex", "gemini"]

    private static func usageProviderKey(_ provider: String) -> String {
        "usageProvider.\(provider).enabled"
    }

    private static func loadEnabledUsageProviders(defaults: UserDefaults = .standard) -> Set<String> {
        var result = Set<String>()
        for provider in usageProviderOrder {
            let key = usageProviderKey(provider)
            // New sources default to enabled. Once a value is written, honor it.
            if defaults.object(forKey: key) == nil || defaults.bool(forKey: key) {
                result.insert(provider)
            }
        }
        return result.isEmpty ? Set(usageProviderOrder) : result
    }

    func isUsageProviderEnabled(_ provider: String) -> Bool {
        enabledUsageProviders.contains(provider)
    }

    func canDisableUsageProvider(_ provider: String) -> Bool {
        enabledUsageProviders.contains(provider) && enabledUsageProviders.count > 1
    }

    func setUsageProvider(_ provider: String, enabled: Bool) {
        guard Self.usageProviderOrder.contains(provider) else { return }
        var next = enabledUsageProviders
        if enabled {
            next.insert(provider)
        } else {
            guard next.count > 1 else { return }
            next.remove(provider)
        }
        enabledUsageProviders = next
        for item in Self.usageProviderOrder {
            UserDefaults.standard.set(next.contains(item), forKey: Self.usageProviderKey(item))
        }
        engine?.setEnabledProviders(next)
    }

    /// True when something is already listening on the port (used to steer the
    /// "stop the old brew service" hint).
    static func isPortInUse(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Human guidance for the port-conflict case (we never run brew ourselves).
    static let brewConflictHint =
        "端口 4317 已被占用，可能是旧版 brew 服务。请在终端执行：\nbrew services stop agents-hud\n然后点击\"重试\"。"

    func retryAfterConflict() {
        guard case .portConflict = status else { return }
        status = .stopped
        start()
    }
}
