import AppKit
import Combine
import CoreGraphics
import AgentsHUDCore

/// Combines every reason a device should be dark. A device turns on only when
/// neither a scheduled range nor the Mac-lock policy requires it to be off.
/// This prevents an unlock event from overriding an active overnight schedule.
@MainActor
final class DisplayPowerController: ObservableObject {
    static let shared = DisplayPowerController()

    @Published private(set) var lockScreenOffDevices: Set<String>

    private static let defaultsKey = "displayOffWhenMacLockedDeviceIDs"
    private let server = ServerController.shared
    private var scheduledOffDevices = Set<String>()
    private var lastAppliedPower: [String: Bool] = [:]
    private var lastOnlineDevices = Set<String>()
    private var isMacLocked = false
    private var notificationTokens: [NSObjectProtocol] = []
    private var devicesCancellable: AnyCancellable?
    private var started = false

    private init() {
        lockScreenOffDevices = Set(
            UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        )
    }

    func start() {
        guard !started else { return }
        started = true
        isMacLocked = Self.currentSessionIsLocked()

        let center = DistributedNotificationCenter.default()
        notificationTokens.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setMacLocked(true) }
        })
        notificationTokens.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setMacLocked(false) }
        })

        devicesCancellable = server.$devices.sink { [weak self] devices in
            Task { @MainActor in self?.devicesChanged(devices) }
        }
        applyAll(force: true)
    }

    func isLockScreenOffEnabled(for deviceID: String) -> Bool {
        lockScreenOffDevices.contains(deviceID)
    }

    func setLockScreenOff(_ enabled: Bool, deviceID: String) {
        if enabled { lockScreenOffDevices.insert(deviceID) }
        else { lockScreenOffDevices.remove(deviceID) }
        UserDefaults.standard.set(lockScreenOffDevices.sorted(), forKey: Self.defaultsKey)
        _ = apply(deviceID: deviceID, force: true)
    }

    /// Called by the scheduler after it has resolved overlapping time ranges.
    @discardableResult
    func setScheduledOff(_ off: Bool, deviceID: String) -> Bool {
        if off { scheduledOffDevices.insert(deviceID) }
        else { scheduledOffDevices.remove(deviceID) }
        return apply(deviceID: deviceID, force: false)
    }

    private func setMacLocked(_ locked: Bool) {
        guard isMacLocked != locked else { return }
        isMacLocked = locked
        applyAll(force: true)
    }

    private func wantsDisplayOff(_ deviceID: String) -> Bool {
        scheduledOffDevices.contains(deviceID)
            || (isMacLocked && lockScreenOffDevices.contains(deviceID))
    }

    @discardableResult
    private func apply(deviceID: String, force: Bool) -> Bool {
        let on = !wantsDisplayOff(deviceID)
        if !force, lastAppliedPower[deviceID] == on { return true }
        let ok = server.deviceGateway.setDisplayPower(on, id: deviceID)
        if ok { lastAppliedPower[deviceID] = on }
        return ok
    }

    private func applyAll(force: Bool) {
        let ids = lockScreenOffDevices
            .union(scheduledOffDevices)
            .union(server.devices.filter { $0.supports(.displayPower) }.map(\.id))
        for id in ids { _ = apply(deviceID: id, force: force) }
    }

    private func devicesChanged(_ devices: [DeviceInfo]) {
        let online = Set(devices.filter { $0.online && $0.supports(.displayPower) }.map(\.id))
        let newlyOnline = online.subtracting(lastOnlineDevices)
        for id in newlyOnline {
            lastAppliedPower[id] = nil
            _ = apply(deviceID: id, force: true)
        }
        for id in lastOnlineDevices.subtracting(online) { lastAppliedPower[id] = nil }
        lastOnlineDevices = online
    }

    private static func currentSessionIsLocked() -> Bool {
        guard let raw = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return raw["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
