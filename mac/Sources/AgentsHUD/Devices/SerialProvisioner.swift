import Foundation
import AgentsHUDCore

/// Provisions a dial over USB serial — the path for boards without Bluetooth
/// (ESP8266). Line-based JSON at 115200 baud (docs/PROTOCOL.md §4b):
///   → {"t":"info?"}                      ← {"t":"info","board":..,"fw":..,"id":..}
///   → {"t":"prov","v":1,"ssid":..,...}   ← {"t":"st","st":"connecting|got_ip|ws_ok|...","ip":..}
@MainActor
final class SerialProvisioner: ObservableObject {
    struct DiscoveredDevice: Identifiable, Equatable, Sendable {
        var id: String { portPath }
        let portPath: String
        let board: String
        let firmware: String
        let deviceId: String
    }

    enum Phase: Equatable {
        case idle
        case opening
        case probing
        case sending
        case deviceStatus(String, ip: String)
        case done(ip: String)
        case failed(String)
    }

    struct DeviceInfo: Equatable {
        var board: String
        var firmware: String
        var id: String
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var info: DeviceInfo?
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var isDiscovering = false

    private var provisionTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?

    /// Continuously watches USB serial ports while the provisioning sheet is
    /// open. New ports are probed once with `info?`; only AgentsHUD firmware is
    /// surfaced as a device, so users never have to choose a raw `/dev` path.
    func startDiscovery() {
        cancel()
        stopDiscovery()
        info = nil
        discoveredDevices = []
        isDiscovering = true
        discoveryTask = Task.detached(priority: .utility) { [weak self] in
            var attempted = Set<String>()
            while !Task.isCancelled {
                let ports = SerialPortLocator.ports()
                let connectedPaths = Set(ports.map(\.path))
                attempted.formIntersection(connectedPaths)
                await self?.removeDisconnectedDevices(keeping: connectedPaths)

                let candidates = ports.filter { !attempted.contains($0.path) }
                attempted.formUnion(candidates.map(\.path))
                await withTaskGroup(of: DiscoveredDevice?.self) { group in
                    for port in candidates {
                        group.addTask { await Self.probe(portPath: port.path) }
                    }
                    for await device in group {
                        guard let device else { continue }
                        await self?.addDiscoveredDevice(device)
                    }
                }

                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        isDiscovering = false
    }

    func cancel() {
        provisionTask?.cancel()
        provisionTask = nil
        phase = .idle
    }

    func provision(portPath: String, ssid: String, password: String, payloadFrom controller: ServerController) {
        cancel()
        let pairing = controller.pairingPayload
        let provJson = CompactSnapshot.encodeOrdered([
            ("t", "prov"),
            ("v", 1),
            ("ssid", ssid),
            ("pw", password),
            ("url", pairing.url),
            ("token", pairing.token),
            ("name", pairing.name),
        ])
        phase = .opening
        provisionTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runFlow(portPath: portPath, provJson: provJson)
        }
    }

    private func addDiscoveredDevice(_ device: DiscoveredDevice) {
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
            discoveredDevices.sort { $0.deviceId < $1.deviceId }
        }
    }

    private func removeDisconnectedDevices(keeping paths: Set<String>) {
        discoveredDevices.removeAll { !paths.contains($0.portPath) }
    }

    nonisolated private static func probe(portPath: String) async -> DiscoveredDevice? {
        guard let port = SerialLine(path: portPath) else { return nil }
        defer { port.close() }

        // Opening a NodeMCU-style USB serial port resets it. Wait for the app
        // firmware to boot before sending the identity request.
        try? await Task.sleep(nanoseconds: 1_800_000_000)
        guard !Task.isCancelled else { return nil }

        for _ in 0..<3 {
            port.writeLine("{\"t\":\"info?\"}")
            if let obj = await port.readJSONLine(
                timeoutMs: 1_500,
                where: { $0["t"] as? String == "info" }
            ) {
                return DiscoveredDevice(
                    portPath: portPath,
                    board: obj["board"] as? String ?? "",
                    firmware: obj["fw"] as? String ?? "",
                    deviceId: obj["id"] as? String ?? ""
                )
            }
            guard !Task.isCancelled else { return nil }
        }
        return nil
    }

    private func setPhase(_ p: Phase) {
        phase = p
    }

    private func setInfo(_ i: DeviceInfo) {
        info = i
    }

    nonisolated private func runFlow(portPath: String, provJson: String) async {
        guard let port = SerialLine(path: portPath) else {
            await setPhase(.failed("打不开串口 \(portPath)"))
            return
        }
        defer { port.close() }

        // Opening the port auto-resets a NodeMCU-style board; give it time to
        // boot before talking.
        try? await Task.sleep(nanoseconds: 1_800_000_000)

        // Probe: ask for device info (also confirms the firmware speaks our
        // protocol rather than being a stock/vendor firmware).
        await setPhase(.probing)
        var gotInfo = false
        for _ in 0..<3 {
            port.writeLine("{\"t\":\"info?\"}")
            if let obj = await port.readJSONLine(timeoutMs: 1500, where: { $0["t"] as? String == "info" }) {
                await setInfo(DeviceInfo(
                    board: obj["board"] as? String ?? "",
                    firmware: obj["fw"] as? String ?? "",
                    id: obj["id"] as? String ?? ""
                ))
                gotInfo = true
                break
            }
            if Task.isCancelled { return }
        }
        guard gotInfo else {
            await setPhase(.failed("设备没有响应（固件太旧或不是 AgentsHUD 固件？先烧录固件再配网）"))
            return
        }

        await setPhase(.sending)
        port.writeLine(provJson)

        // Follow status lines until ws_ok / a terminal failure (90s budget:
        // WiFi join + WS connect can be slow on 8266).
        var lastIp = ""
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !Task.isCancelled {
            guard let obj = await port.readJSONLine(timeoutMs: 3000, where: { $0["t"] as? String == "st" }) else {
                continue
            }
            let st = obj["st"] as? String ?? ""
            let ip = obj["ip"] as? String ?? ""
            if !ip.isEmpty { lastIp = ip }
            switch st {
            case "ws_ok":
                await setPhase(.done(ip: lastIp))
                return
            case "bad_pass":
                await setPhase(.failed("WiFi 密码错误"))
                return
            case "ap_not_found":
                await setPhase(.failed("找不到该 WiFi（8266 只支持 2.4GHz）"))
                return
            case "server_fail":
                await setPhase(.failed("设备连上 WiFi（\(lastIp)）但连不上本机服务，请检查防火墙/局域网权限"))
                return
            default:
                await setPhase(.deviceStatus(st, ip: ip))
            }
        }
        if !Task.isCancelled {
            await setPhase(.failed("等待设备连接超时（当前 IP：\(lastIp.isEmpty ? "未获取" : lastIp)）"))
        }
    }
}

/// Minimal blocking-with-timeout line reader over a POSIX serial port.
final class SerialLine: @unchecked Sendable {
    private let fd: Int32
    private var buffer = Data()

    init?(path: String) {
        fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        var tio = termios()
        if tcgetattr(fd, &tio) == 0 {
            cfmakeraw(&tio)
            cfsetspeed(&tio, speed_t(B115200))
            tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
            tcsetattr(fd, TCSANOW, &tio)
        }
        // Deassert DTR/RTS so the NodeMCU auto-reset circuit lets the chip run.
        var bits: Int32 = TIOCM_DTR | TIOCM_RTS
        _ = ioctl(fd, TIOCMBIC, &bits)
        tcflush(fd, TCIOFLUSH)
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
    }

    func writeLine(_ line: String) {
        let data = Data((line + "\n").utf8)
        data.withUnsafeBytes { raw in
            _ = write(fd, raw.baseAddress, raw.count)
        }
    }

    /// Reads until a line parses as a JSON object matching `predicate`, or the
    /// timeout elapses. Non-matching lines (boot logs etc.) are skipped.
    func readJSONLine(timeoutMs: Int, where predicate: ([String: Any]) -> Bool) async -> [String: Any]? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            while let idx = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.subdata(in: buffer.startIndex..<idx)
                buffer.removeSubrange(buffer.startIndex...idx)
                if let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                   predicate(obj) {
                    return obj
                }
            }
            var tmp = [UInt8](repeating: 0, count: 512)
            let n = read(fd, &tmp, tmp.count)
            if n > 0 {
                buffer.append(contentsOf: tmp[0..<n])
            } else {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return nil
    }
}
