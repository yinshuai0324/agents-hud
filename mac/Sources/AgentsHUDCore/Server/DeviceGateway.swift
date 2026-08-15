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
    /// Whether the usage snapshot stream is being pushed to this device.
    public var usageEnabled: Bool = true
    /// True while a WebSocket connection is live (vs. a known-but-offline device).
    public var online: Bool = true
}

/// Tracks connected devices, streams them usage snapshots, and lets the app
/// push directed content messages (text / animation / config). One instance is
/// shared by all /device WebSocket connections; the UI observes `onDevicesChanged`.
public final class DeviceGateway: @unchecked Sendable {
    private let lock = NSLock()
    private var devices: [String: DeviceInfo] = [:]
    /// Live send channels, keyed by device id (set once hello/query id is known).
    private var senders: [String: @Sendable (String) -> Void] = [:]
    /// Devices whose usage-snapshot push is turned off (default is on).
    private var usageOff: Set<String> = []
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

    private func notifyLocked() {
        let snapshot = devices.values.sorted { $0.id < $1.id }
        let fns = Array(changeListeners.values)
        lock.unlock()
        for fn in fns { fn(snapshot) }
        lock.lock()
    }

    // MARK: - Connection lifecycle (called from DeviceWSHandler)

    /// Register the send channel for a device connection.
    func attach(id: String, sender: @escaping @Sendable (String) -> Void) {
        guard !id.isEmpty else { return }
        lock.lock()
        senders[id] = sender
        lock.unlock()
    }

    func detach(id: String) {
        guard !id.isEmpty else { return }
        lock.lock()
        senders[id] = nil
        if var d = devices[id] { d.online = false; devices[id] = d }
        notifyLocked()
        lock.unlock()
    }

    /// Register/refresh a device from its hello message (or query fallback).
    func upsert(id: String, board: String, firmware: String, address: String) {
        guard !id.isEmpty else { return }
        lock.lock()
        var d = devices[id] ?? DeviceInfo(id: id, board: board, firmware: firmware, lastSeen: nowMs(), address: address)
        d.board = board.isEmpty ? d.board : board
        d.firmware = firmware.isEmpty ? d.firmware : firmware
        d.address = address.isEmpty ? d.address : address
        d.lastSeen = nowMs()
        d.online = true
        d.usageEnabled = !usageOff.contains(id)
        devices[id] = d
        notifyLocked()
        lock.unlock()
    }

    func touch(id: String) {
        lock.lock()
        devices[id]?.lastSeen = nowMs()
        lock.unlock()
    }

    /// Whether the usage snapshot should currently be pushed to this device.
    /// Unknown ids default to on (usage is the default content).
    func shouldPushUsage(id: String) -> Bool {
        if id.isEmpty { return true }
        lock.lock()
        defer { lock.unlock() }
        guard let device = devices[id] else { return true }
        return device.supports(.usageSnapshot) && !usageOff.contains(id)
    }

    // MARK: - Directed control (called from the app UI)

    /// Toggle the usage-snapshot stream for a device.
    @discardableResult
    public func setUsageEnabled(_ enabled: Bool, id: String) -> Bool {
        guard !id.isEmpty else { return false }
        lock.lock()
        guard let device = devices[id], device.supports(.usageSnapshot) else {
            lock.unlock()
            return false
        }
        if enabled { usageOff.remove(id) } else { usageOff.insert(id) }
        if var d = devices[id] { d.usageEnabled = enabled; devices[id] = d }
        notifyLocked()
        lock.unlock()
        return true
    }

    /// Send a raw JSON message to one device. Returns false if it's offline.
    @discardableResult
    public func send(to id: String, _ message: String) -> Bool {
        lock.lock()
        let sender = senders[id]
        lock.unlock()
        sender?(message)
        return sender != nil
    }

    /// Push a text card to a device. `hold` seconds > 0 auto-reverts to the
    /// usage view; 0 keeps it until the next message.
    @discardableResult
    public func sendText(to id: String, title: String, body: String, holdSeconds: Int = 0) -> Bool {
        lock.lock()
        let supportsText = devices[id]?.supports(.textCard) == true
        lock.unlock()
        guard supportsText else { return false }
        let msg = CompactSnapshot.encodeOrdered([
            ("t", "text"),
            ("title", title),
            ("body", body),
            ("hold", holdSeconds),
        ])
        return send(to: id, msg)
    }

    /// Dismiss the current text card immediately and return to the usage page.
    /// This explicit command is used by start/end schedules; it avoids relying
    /// on a long `hold` timer that can drift while the Mac sleeps.
    @discardableResult
    public func clearText(on id: String) -> Bool {
        lock.lock()
        let supportsText = devices[id]?.supports(.textCard) == true
        lock.unlock()
        guard supportsText else { return false }
        return send(to: id, CompactSnapshot.encodeOrdered([
            ("t", "text"),
            ("clear", true),
            // Backward compatibility: older text-capable firmware ignores
            // `clear`, shows an empty card, then returns to usage after 1s.
            ("title", ""),
            ("body", ""),
            ("hold", 1),
        ]))
    }

    /// Keep networking alive while turning only the physical display on/off.
    @discardableResult
    public func setDisplayPower(_ on: Bool, id: String) -> Bool {
        lock.lock()
        let supported = devices[id]?.supports(.displayPower) == true
        lock.unlock()
        guard supported else { return false }
        return send(to: id, CompactSnapshot.encodeOrdered([
            ("t", "display"),
            ("on", on),
        ]))
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
