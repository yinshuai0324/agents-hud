import Foundation
import FlyingFox

/// Collapse whitespace and cap length for inline display (server.ts oneLine).
func oneLine(_ s: String, max: Int) -> String {
    let t = s.replacingRegex("\\s+", with: " ").trimmingCharacters(in: .whitespaces)
    if t.count > max {
        return String(t.prefix(max - 1)) + "…"
    }
    return t
}

func baseName(_ p: String) -> String {
    let parts = p.split(separator: "/").filter { !$0.isEmpty }
    return parts.last.map(String.init) ?? p
}

/// A short human label for a tool call, e.g. "Bash: npm run build" (server.ts
/// toolSummary — the string is displayed verbatim by the Android app).
func toolSummary(name: String, input: [String: Any]?) -> String {
    let i = input ?? [:]
    switch name {
    case "Bash":
        if let cmd = i["command"] as? String, !cmd.isEmpty {
            return "Bash: \(oneLine(cmd, max: 40))"
        }
        return "Bash"
    case "Read", "Edit", "Write", "NotebookEdit":
        if let fp = i["file_path"] as? String, !fp.isEmpty {
            return "\(name) \(baseName(fp))"
        }
        return name
    case "Grep":
        if let p = i["pattern"] as? String, !p.isEmpty {
            return "Grep \(oneLine(p, max: 24))"
        }
        return "Grep"
    case "Glob":
        if let p = i["pattern"] as? String, !p.isEmpty {
            return "Glob \(oneLine(p, max: 24))"
        }
        return "Glob"
    default:
        return name
    }
}

/// HTTP + WebSocket server — port of server.ts on FlyingFox.
///  - POST /hooks        : Claude Code hook callbacks
///  - POST /statusline   : Claude Code statusLine payloads
///  - GET  /api/snapshot : current snapshot (REST, first paint / polling)
///  - GET  /healthz      : liveness
///  - WS   /             : live snapshot stream (Android / local UI)
///  - WS   /device       : compact snapshot stream for ESP32 dials
public final class HUDServer: @unchecked Sendable {
    private let cfg: Config
    private let engine: StateEngine
    public let deviceGateway: DeviceGateway
    public let serverVersion: String
    private var server: HTTPServer?
    private var runTask: Task<Void, Never>?

    public init(
        cfg: Config,
        engine: StateEngine,
        deviceGateway: DeviceGateway = DeviceGateway(),
        serverVersion: String = "0.0.0"
    ) {
        self.cfg = cfg
        self.engine = engine
        self.deviceGateway = deviceGateway
        self.serverVersion = serverVersion
    }

    public func start() async throws {
        let server = HTTPServer(address: try .inet(ip4: cfg.host, port: UInt16(cfg.port)))
        self.server = server

        let cfg = self.cfg
        let engine = self.engine

        await server.appendRoute("GET /healthz") { _ in
            Self.json(.ok, ["ok": true])
        }

        await server.appendRoute("GET /api/snapshot") { req in
            guard Self.authOk(cfg, req) else {
                return Self.json(.unauthorized, ["error": "unauthorized"])
            }
            return Self.jsonData(.ok, engine.buildSnapshot().jsonData())
        }

        await server.appendRoute("POST /hooks") { req in
            let body = try await req.bodyData
            guard let data = Self.parseBody(body) else {
                return Self.json(.badRequest, ["error": "bad json"])
            }
            let event = stringField(data["hook_event_name"] ?? data["event"])
            let sessionId = stringField(data["session_id"] ?? data["sessionId"])
            let cwd = data["cwd"] as? String
            var toolLabel: String?
            if let toolName = data["tool_name"] as? String {
                toolLabel = toolSummary(name: toolName, input: data["tool_input"] as? [String: Any])
            }
            engine.handleHook(event: event, sessionId: sessionId, cwd: cwd, toolLabel: toolLabel)
            return Self.json(.ok, ["ok": true])
        }

        await server.appendRoute("POST /statusline") { req in
            let body = try await req.bodyData
            guard let data = Self.parseBody(body) else {
                return Self.json(.badRequest, ["error": "bad json"])
            }
            engine.handleStatusline(data)
            return Self.json(.ok, ["ok": true])
        }

        // WS /device — ESP32 dials. Registered before the catch-all WS route.
        await server.appendRoute(
            "GET /device",
            to: AuthedWebSocket(cfg: cfg) { [deviceGateway, serverVersion] req in
                DeviceWSHandler(
                    engine: engine,
                    gateway: deviceGateway,
                    serverVersion: serverVersion,
                    queryId: Self.queryValue(req, "id"),
                    queryBoard: Self.queryValue(req, "board"),
                    queryFw: Self.queryValue(req, "fw"),
                    address: Self.remoteDescription(req)
                )
            }
        )

        // WS / — full snapshot stream (Android + local UI).
        await server.appendRoute(
            "GET /",
            to: AuthedWebSocket(cfg: cfg) { _ in
                SnapshotWSHandler(engine: engine)
            }
        )

        let task = Task<Void, Never> {
            do { try await server.run() } catch { /* stopped or failed to bind */ }
        }
        runTask = task
        try await server.waitUntilListening(timeout: 10)
    }

    public func stop() async {
        await server?.stop(timeout: 1)
        runTask?.cancel()
        runTask = nil
        server = nil
    }

    // MARK: - Helpers

    static func queryValue(_ req: HTTPRequest, _ name: String) -> String {
        req.query.first(where: { $0.name == name })?.value ?? ""
    }

    static func remoteDescription(_ req: HTTPRequest) -> String {
        switch req.remoteAddress {
        case let .ip4(host, port: _): return host
        case let .ip6(host, port: _): return host
        case let .unix(path): return path
        case nil: return ""
        }
    }

    static func authOk(_ cfg: Config, _ req: HTTPRequest) -> Bool {
        if cfg.authToken.isEmpty { return true }
        let queryToken = queryValue(req, "token")
        var bearer: String?
        if let header = req.headers[HTTPHeader("Authorization")], header.hasPrefix("Bearer ") {
            bearer = String(header.dropFirst(7))
        }
        return queryToken == cfg.authToken || bearer == cfg.authToken
    }

    static func parseBody(_ body: Data) -> [String: Any]? {
        if body.isEmpty { return [:] }
        if body.count > 1_000_000 { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    static func json(_ status: HTTPStatusCode, _ obj: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        return jsonData(status, data)
    }

    static func jsonData(_ status: HTTPStatusCode, _ data: Data) -> HTTPResponse {
        HTTPResponse(
            statusCode: status,
            headers: [
                HTTPHeader("Content-Type"): "application/json; charset=utf-8",
                HTTPHeader("Access-Control-Allow-Origin"): "*",
            ],
            body: data
        )
    }
}

/// Checks the shared token before upgrading to a WebSocket; 401 otherwise.
/// (The Node server accepted then closed 4401 — clients treat both as a failed
/// connect and retry, verified against the Android client's reconnect path.)
struct AuthedWebSocket: HTTPHandler {
    let cfg: Config
    let makeHandler: @Sendable (HTTPRequest) -> any WSMessageHandler

    init(cfg: Config, makeHandler: @escaping @Sendable (HTTPRequest) -> any WSMessageHandler) {
        self.cfg = cfg
        self.makeHandler = makeHandler
    }

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard HUDServer.authOk(cfg, request) else {
            return HUDServer.json(.unauthorized, ["error": "unauthorized"])
        }
        let ws = WebSocketHTTPHandler(handler: MessageFrameWSHandler(handler: makeHandler(request)))
        return try await ws.handleRequest(request)
    }
}

/// WS / — pushes the full Snapshot JSON: one on connect, then on every change.
struct SnapshotWSHandler: WSMessageHandler {
    let engine: StateEngine

    func makeMessages(for client: AsyncStream<WSMessage>) async throws -> AsyncStream<WSMessage> {
        let engine = self.engine
        return AsyncStream { continuation in
            let initial = engine.buildSnapshot().jsonData()
            continuation.yield(.text(String(decoding: initial, as: UTF8.self)))
            let off = engine.onSnapshot { snap in
                continuation.yield(.text(String(decoding: snap.jsonData(), as: UTF8.self)))
            }
            // Drain the inbound stream so the connection close ends us.
            let reader = Task {
                for await _ in client {}
                continuation.finish()
            }
            continuation.onTermination = { _ in
                off()
                reader.cancel()
            }
        }
    }
}

/// WS /device — compact snapshots for the dial: one on connect + on change,
/// plus a 3s timer push that doubles as an application-level heartbeat
/// (firmware treats >30s of silence as "server unreachable").
struct DeviceWSHandler: WSMessageHandler {
    let engine: StateEngine
    let gateway: DeviceGateway
    let serverVersion: String
    let queryId: String
    let queryBoard: String
    let queryFw: String
    let address: String

    func makeMessages(for client: AsyncStream<WSMessage>) async throws -> AsyncStream<WSMessage> {
        let engine = self.engine
        let gateway = self.gateway
        let serverVersion = self.serverVersion
        let host = gateway.hostName
        let queryId = self.queryId
        let queryBoard = self.queryBoard
        let queryFw = self.queryFw
        let address = self.address

        return AsyncStream { continuation in
            // Query params double as a hello so the device shows up even if
            // the explicit hello frame is lost.
            let idBox = LockedBox(initial: queryId)
            if !queryId.isEmpty {
                gateway.upsert(id: queryId, board: queryBoard, firmware: queryFw, address: address)
            }

            @Sendable func pushSnap(_ snap: Snapshot) {
                continuation.yield(.text(CompactSnapshot.json(from: snap, hostName: host)))
            }

            pushSnap(engine.buildSnapshot())
            let off = engine.onSnapshot { pushSnap($0) }

            // 3s heartbeat push (unconditional, like the BLE daemon's cadence).
            let heartbeat = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if Task.isCancelled { break }
                    pushSnap(engine.buildSnapshot())
                    let id = idBox.value
                    if !id.isEmpty { gateway.touch(id: id) }
                }
            }

            let reader = Task {
                for await message in client {
                    guard case let .text(text) = message else { continue }
                    if let hello = DeviceGateway.parseHello(text) {
                        idBox.value = hello.id
                        gateway.upsert(id: hello.id, board: hello.board, firmware: hello.fw, address: address)
                        continuation.yield(.text(gateway.hiMessage(serverVersion: serverVersion)))
                    }
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                off()
                heartbeat.cancel()
                reader.cancel()
                let id = idBox.value
                if !id.isEmpty { gateway.remove(id: id) }
            }
        }
    }
}

/// Tiny thread-safe box (device id becomes known mid-connection).
final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String
    init(initial: String) { stored = initial }
    var value: String {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
