import Foundation
import Combine
import AppKit

enum ConnectionState { case connecting, connected, disconnected }

/// Sessions older than this (by lastActivity) are treated as inactive — mirrors
/// `ACTIVE_WINDOW_MS` in `DashboardScreen.kt`.
private let activeWindowMs: Double = 60 * 60 * 1000

/// Connects to the local Agents-HUD server (`ws://127.0.0.1:4317/`) and republishes
/// the live `Snapshot`. No QR pairing: the server runs on this same machine.
@MainActor
final class SignalClient: ObservableObject {
    static let shared = SignalClient()

    @Published var snapshot: Snapshot?
    @Published var connection: ConnectionState = .connecting
    /// Ticks every 0.5s so relative times, the active-session window, and the
    /// menu-bar blink all recompute without a fresh snapshot.
    @Published var now: Date = Date()

    private var task: URLSessionWebSocketTask?
    private var reconnectDelay: UInt64 = 1
    private var epoch = 0
    private var started = false

    // Per-session last-seen state, to detect transitions for notifications.
    private var lastStates: [String: String] = [:]
    private var hasBaseline = false

    // MARK: Config (read live from UserDefaults; defaults match the server)
    private var host: String { UserDefaults.standard.string(forKey: "host") ?? "127.0.0.1" }
    private var port: Int { let p = UserDefaults.standard.integer(forKey: "port"); return p == 0 ? 4317 : p }
    private var token: String { UserDefaults.standard.string(forKey: "token") ?? "" }

    // MARK: Derived view state (mirrors DashboardScreen.kt)

    /// Sessions touched within the last hour. Empty while disconnected.
    var activeSessions: [Session] {
        guard connection == .connected, let snap = snapshot else { return [] }
        let nowMs = now.timeIntervalSince1970 * 1000
        return snap.sessions.filter {
            $0.lastActivity > 0 && nowMs - Double($0.lastActivity) < activeWindowMs
        }
    }

    /// The light follows the most recently active session; quiet if none; nil
    /// (dark) while disconnected.
    var dominant: LightState? {
        guard connection == .connected else { return nil }
        if let first = activeSessions.first { return LightState.from(first.state) }
        return .quiet
    }

    /// Per-state tally over the active set.
    var counts: [LightState: Int] {
        var d: [LightState: Int] = [:]
        for s in activeSessions { d[LightState.from(s.state), default: 0] += 1 }
        return d
    }

    /// Whether the menu-bar dot should be in its dimmed blink phase right now.
    var blinkDim: Bool {
        guard let dom = dominant, dom == .error || dom == .notify else { return false }
        return Int(now.timeIntervalSince1970 * 2) % 2 == 0
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        startClock()
        if snapshot == nil { connection = .connecting }
        fetchInitial()
        connect()
    }

    /// Manual reconnect (refresh button / settings change). Invalidates pending
    /// callbacks and re-reads host/port/token.
    func reconnect() {
        task?.cancel(); task = nil
        epoch += 1
        reconnectDelay = 1
        if snapshot == nil { connection = .connecting }
        fetchInitial()
        connect()
    }

    private func startClock() {
        Task { @MainActor [weak self] in
            while true {
                guard let self else { break }
                self.now = Date()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: Networking

    private func connect() {
        epoch += 1
        let myEpoch = epoch
        guard let url = wsURL() else { return }
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        listen(myEpoch)
    }

    private func listen(_ e: Int) {
        task?.receive { [weak self] result in
            // Bind strongly here so the inner Task captures a constant, not the
            // weak `self` var (which older Swift rejects in concurrent code).
            guard let self else { return }
            switch result {
            case .success(let message):
                var text: String?
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8)
                @unknown default: text = nil
                }
                Task { @MainActor in
                    guard e == self.epoch else { return }
                    self.connection = .connected
                    self.reconnectDelay = 1
                    if let text { self.decode(text) }
                    self.listen(e)
                }
            case .failure:
                Task { @MainActor in
                    guard e == self.epoch else { return }
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        connection = .disconnected
        task?.cancel(); task = nil
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 10)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            self?.connect()
        }
    }

    private func fetchInitial() {
        guard let url = httpURL() else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self, let data else { return }
            Task { @MainActor in
                if let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
                    if self.snapshot == nil { self.snapshot = snap }
                    self.connection = .connected
                    if !self.hasBaseline {
                        for s in snap.sessions { self.lastStates[s.id] = s.state }
                        self.hasBaseline = true
                    }
                }
            }
        }.resume()
    }

    private func decode(_ text: String) {
        guard let data = text.data(using: .utf8),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        snapshot = snap
        noteTransitions(snap)
    }

    /// Fire a notification when a session enters an attention state. The first
    /// snapshot (or first after a fresh launch) just seeds the baseline so we
    /// don't notify for states that were already in flight.
    private func noteTransitions(_ snap: Snapshot) {
        guard hasBaseline else {
            for s in snap.sessions { lastStates[s.id] = s.state }
            hasBaseline = true
            return
        }
        for s in snap.sessions where lastStates[s.id] != s.state {
            Notifier.shared.sessionEntered(state: s.state, project: s.project, cwd: s.cwd)
        }
        for s in snap.sessions { lastStates[s.id] = s.state }
        let ids = Set(snap.sessions.map(\.id))
        lastStates = lastStates.filter { ids.contains($0.key) }
    }

    private func wsURL() -> URL? { buildURL(scheme: "ws", path: "/") }
    private func httpURL() -> URL? { buildURL(scheme: "http", path: "/api/snapshot") }

    private func buildURL(scheme: String, path: String) -> URL? {
        var c = URLComponents()
        c.scheme = scheme
        c.host = host
        c.port = port
        c.path = path
        if !token.isEmpty { c.queryItems = [URLQueryItem(name: "token", value: token)] }
        return c.url
    }
}
