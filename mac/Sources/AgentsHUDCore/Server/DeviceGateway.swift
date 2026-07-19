import Foundation

/// A hardware dial connected over the /device WebSocket.
public struct DeviceInfo: Identifiable, Sendable, Equatable {
    /// Short device id, e.g. "F232" (WiFi MAC suffix).
    public var id: String
    /// Board model id, e.g. "ws175".
    public var board: String
    /// Firmware semver reported in the hello message.
    public var firmware: String
    /// Epoch ms of the last frame received from the device.
    public var lastSeen: Double
    /// Remote address, when known.
    public var address: String
}

/// Tracks connected ESP32 devices and feeds them compact snapshots. One
/// instance is shared by all /device WebSocket connections; the app's device
/// UI observes `onDevicesChanged`.
public final class DeviceGateway: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [String: DeviceInfo] = [:]
    private var changeListeners: [UUID: @Sendable ([DeviceInfo]) -> Void] = [:]
    public let hostName: String

    public init(hostName: String = Host.current().localizedName ?? "Mac") {
        self.hostName = hostName
    }

    public var connectedDevices: [DeviceInfo] {
        lock.lock()
        defer { lock.unlock() }
        return devices.values.sorted { $0.id < $1.id }
    }

    public func onDevicesChanged(_ fn: @escaping @Sendable ([DeviceInfo]) -> Void) -> () -> Void {
        let id = UUID()
        lock.lock()
        changeListeners[id] = fn
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.changeListeners[id] = nil
            self.lock.unlock()
        }
    }

    /// Register/refresh a device from its hello message (or query fallback).
    func upsert(id: String, board: String, firmware: String, address: String) {
        guard !id.isEmpty else { return }
        lock.lock()
        devices[id] = DeviceInfo(
            id: id, board: board, firmware: firmware,
            lastSeen: nowMs(), address: address
        )
        let snapshot = devices.values.sorted { $0.id < $1.id }
        let fns = Array(changeListeners.values)
        lock.unlock()
        for fn in fns { fn(snapshot) }
    }

    func touch(id: String) {
        lock.lock()
        devices[id]?.lastSeen = nowMs()
        lock.unlock()
    }

    func remove(id: String) {
        guard !id.isEmpty else { return }
        lock.lock()
        devices[id] = nil
        let snapshot = devices.values.sorted { $0.id < $1.id }
        let fns = Array(changeListeners.values)
        lock.unlock()
        for fn in fns { fn(snapshot) }
    }

    /// Parse a device→server message; returns the hello fields when it is one.
    static func parseHello(_ text: String) -> (id: String, board: String, fw: String)? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              obj["t"] as? String == "hello" else { return nil }
        return (
            id: obj["id"] as? String ?? "",
            board: obj["board"] as? String ?? "",
            fw: obj["fw"] as? String ?? ""
        )
    }

    /// The hello response sent back to a device.
    func hiMessage(serverVersion: String) -> String {
        CompactSnapshot.encodeOrdered([
            ("t", "hi"),
            ("name", hostName),
            ("ver", serverVersion),
        ])
    }
}
