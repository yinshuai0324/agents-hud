import Foundation
import Combine
import AgentsHUDCore

/// A per-device scheduled action. Point tasks fire at HH:mm every day; text
/// tasks may also own a start/end range and restore the usage page at the end.
/// Persisted to UserDefaults so schedules survive restarts.
struct ScheduledTask: Codable, Identifiable, Equatable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        case showText
        case screenOff
        case usageOn
        case usageOff

        var id: String { rawValue }
        var label: String {
            switch self {
            case .showText: return "显示文字"
            case .screenOff: return "关闭屏幕"
            case .usageOn: return "开启用量推送"
            case .usageOff: return "关闭用量推送"
            }
        }

        var requiredFeature: DeviceFeature {
            switch self {
            case .showText: return .textCard
            case .screenOff: return .displayPower
            case .usageOn, .usageOff: return .usageSnapshot
            }
        }

        func isSupported(by device: DeviceInfo) -> Bool {
            device.supports(requiredFeature)
        }
    }

    var id: UUID = UUID()
    var deviceId: String
    /// Captured when the task is created. Optional keeps previously persisted
    /// schedules decodable; live device metadata is preferred when available.
    var boardId: String? = nil
    var hour: Int
    var minute: Int
    var enabled: Bool = true
    var action: Action
    // Only meaningful for .showText.
    var textTitle: String = ""
    var textBody: String = ""
    var holdSeconds: Int = 0
    /// Optional daily end time for a persistent text range. Optional fields
    /// keep schedules created by older app versions decodable.
    var endHour: Int? = nil
    var endMinute: Int? = nil

    var timeText: String { String(format: "%02d:%02d", hour, minute) }
    var endTimeText: String? {
        guard let endHour, let endMinute else { return nil }
        return String(format: "%02d:%02d", endHour, endMinute)
    }

    var hasTimeRange: Bool {
        guard action == .showText || action == .screenOff,
              let endHour, let endMinute else { return false }
        return hour * 60 + minute != endHour * 60 + endMinute
    }

    var scheduleText: String {
        guard hasTimeRange, let endTimeText else { return timeText }
        return "\(timeText)–\(endTimeText)"
    }

    var summary: String {
        switch action {
        case .showText:
            if hasTimeRange { return "时段内显示「\(textBody)」" }
            let hold = holdSeconds == 0 ? "常驻" : "\(holdSeconds) 秒"
            return "显示「\(textBody)」· \(hold)"
        case .screenOff:
            return "时段内关闭屏幕"
        case .usageOn: return action.label
        case .usageOff: return action.label
        }
    }
}

/// Owns the schedule list and fires due tasks against the device gateway.
/// Checks every 20s and accepts a short grace window so a busy run loop or a
/// brief system sleep cannot silently skip a task. Each task still fires only
/// once per local calendar day.
@MainActor
final class DeviceScheduler: ObservableObject {
    static let shared = DeviceScheduler()

    @Published private(set) var tasks: [ScheduledTask] = []
    /// Last fire outcome per task id, for UI feedback ("已发送" / "设备不在线").
    @Published private(set) var lastResult: [UUID: String] = [:]

    private static let defaultsKey = "scheduledTasks"
    private static let rangeStateKey = "scheduledTaskRangeState"
    private static let displayOffStateKey = "scheduledDisplayOffRangeDeviceIDs"
    private static let fireGrace: TimeInterval = 5 * 60
    private var timer: Timer?
    /// Minute keys ("yyyyMMdd HH:mm" + task id) already fired, so the 20s tick
    /// doesn't re-fire within the same minute.
    private var fired: Set<String> = []
    /// The range task that most recently took over each device. Persisting this
    /// lets an app restart after the end time clear a card left on the device.
    private var displayedRangeByDevice: [String: UUID] = [:]
    private var displayOffRangeDevices = Set<String>()
    private var reconciledRangeDevices = Set<String>()

    private init() {
        load()
        loadRangeState()
        displayOffRangeDevices = Set(
            UserDefaults.standard.stringArray(forKey: Self.displayOffStateKey) ?? []
        )
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 20, repeats: true) { _ in
            Task { @MainActor in DeviceScheduler.shared.tick() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    // MARK: - CRUD

    func tasks(for deviceId: String) -> [ScheduledTask] {
        tasks
            .filter { $0.deviceId == deviceId }
            .sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }

    func add(_ task: ScheduledTask) {
        tasks.append(task)
        save()
        tick()
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        lastResult[id] = nil
        save()
        tick()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].enabled = enabled
        save()
        tick()
    }

    // MARK: - Firing

    private func tick() {
        let now = Date()
        let cal = Calendar.current
        let day = cal.dateComponents([.year, .month, .day], from: now)
        guard let startOfDay = cal.date(from: day) else { return }
        let dayKey = Self.dayKey(from: day)

        for task in tasks where task.enabled && !task.hasTimeRange && task.action != .screenOff {
            guard let due = cal.date(
                bySettingHour: min(max(task.hour, 0), 23),
                minute: min(max(task.minute, 0), 59),
                second: 0,
                of: startOfDay
            ) else { continue }
            let lateness = now.timeIntervalSince(due)
            guard lateness >= 0, lateness < Self.fireGrace else { continue }
            let key = "\(dayKey)#\(task.id.uuidString)"
            guard !fired.contains(key) else { continue }
            fired.insert(key)
            performPoint(task)
        }
        reconcileTextRanges(now: now, calendar: cal)
        reconcileDisplayOffRanges(now: now, calendar: cal)
        // Yesterday's entries can never match today's deduplication key.
        fired = fired.filter { $0.hasPrefix(dayKey) }
    }

    private static func dayKey(from comps: DateComponents) -> String {
        String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    private func performPoint(_ task: ScheduledTask) {
        let server = ServerController.shared
        let gateway = server.deviceGateway
        let board = server.devices.first(where: { $0.id == task.deviceId })?.board
            ?? task.boardId
            ?? ""
        guard BoardRegistry.supports(task.action.requiredFeature, board: board) else {
            lastResult[task.id] = "设备不支持此功能"
            return
        }
        switch task.action {
        case .showText:
            let ok = gateway.sendText(
                to: task.deviceId,
                title: task.textTitle,
                body: task.textBody,
                holdSeconds: task.holdSeconds
            )
            lastResult[task.id] = ok ? "已发送" : "上次触发时设备不在线"
        case .screenOff:
            // Screen-off tasks are always ranges; malformed legacy data is
            // ignored by tick rather than turning a display off indefinitely.
            break
        case .usageOn:
            let ok = gateway.setUsageEnabled(true, id: task.deviceId)
            lastResult[task.id] = ok ? "已开启" : "上次触发时设备不在线"
        case .usageOff:
            let ok = gateway.setUsageEnabled(false, id: task.deviceId)
            lastResult[task.id] = ok ? "已关闭" : "上次触发时设备不在线"
        }
    }

    private func reconcileDisplayOffRanges(now: Date, calendar: Calendar) {
        let offTasks = tasks.filter { $0.enabled && $0.action == .screenOff && $0.hasTimeRange }
        var activeByDevice: [String: [ScheduledTask]] = [:]
        for task in offTasks where activeOccurrenceStart(for: task, at: now, calendar: calendar) != nil {
            activeByDevice[task.deviceId, default: []].append(task)
        }

        let taskDeviceIDs = Set(offTasks.map(\.deviceId))
        let deviceIDs = taskDeviceIDs.union(displayOffRangeDevices)
        for deviceID in deviceIDs {
            let activeTasks = activeByDevice[deviceID] ?? []
            let shouldBeOff = !activeTasks.isEmpty
            let wasOff = displayOffRangeDevices.contains(deviceID)
            guard shouldBeOff || wasOff else { continue }

            let ok = DisplayPowerController.shared.setScheduledOff(shouldBeOff, deviceID: deviceID)
            if shouldBeOff {
                if ok {
                    displayOffRangeDevices.insert(deviceID)
                    for task in activeTasks { lastResult[task.id] = "时段生效 · 屏幕已关闭" }
                    saveDisplayOffState()
                } else {
                    for task in activeTasks { lastResult[task.id] = "等待设备在线后关屏" }
                }
            } else if ok {
                displayOffRangeDevices.remove(deviceID)
                for task in offTasks where task.deviceId == deviceID {
                    lastResult[task.id] = "关屏时段结束"
                }
                saveDisplayOffState()
            }
        }
    }

    /// Selects the currently active text range per device. Overlapping ranges
    /// are deterministic: the range with the most recent start wins; when it
    /// ends, the still-active earlier range resumes instead of flashing usage.
    private func reconcileTextRanges(now: Date, calendar: Calendar) {
        let rangeTasks = tasks.filter { $0.enabled && $0.action == .showText && $0.hasTimeRange }
        var desired: [String: (task: ScheduledTask, start: Date)] = [:]
        for task in rangeTasks {
            guard let start = activeOccurrenceStart(for: task, at: now, calendar: calendar) else { continue }
            if let old = desired[task.deviceId], old.start >= start { continue }
            desired[task.deviceId] = (task, start)
        }

        let deviceIDs = Set(rangeTasks.map(\.deviceId)).union(displayedRangeByDevice.keys)
        for deviceID in deviceIDs {
            let target = desired[deviceID]?.task
            let currentID = displayedRangeByDevice[deviceID]
            let firstReconcile = !reconciledRangeDevices.contains(deviceID)
            if target?.id == currentID, !firstReconcile { continue }

            if let target {
                guard performRangeStart(target) else { continue }
                displayedRangeByDevice[deviceID] = target.id
                reconciledRangeDevices.insert(deviceID)
                saveRangeState()
            } else if let currentID {
                guard ServerController.shared.deviceGateway.clearText(on: deviceID) else {
                    if tasks.contains(where: { $0.id == currentID }) {
                        lastResult[currentID] = "等待设备在线后恢复用量"
                    }
                    continue
                }
                displayedRangeByDevice[deviceID] = nil
                reconciledRangeDevices.insert(deviceID)
                lastResult[currentID] = "时段结束 · 已恢复用量"
                saveRangeState()
            } else {
                reconciledRangeDevices.insert(deviceID)
            }
        }
    }

    private func performRangeStart(_ task: ScheduledTask) -> Bool {
        let server = ServerController.shared
        let board = server.devices.first(where: { $0.id == task.deviceId })?.board
            ?? task.boardId
            ?? ""
        guard BoardRegistry.supports(.textCard, board: board) else {
            lastResult[task.id] = "设备不支持文字时段"
            return false
        }
        let ok = server.deviceGateway.sendText(
            to: task.deviceId,
            title: task.textTitle,
            body: task.textBody,
            holdSeconds: 0
        )
        lastResult[task.id] = ok ? "时段生效 · 正在显示" : "等待设备在线后显示"
        return ok
    }

    private func activeOccurrenceStart(
        for task: ScheduledTask,
        at now: Date,
        calendar: Calendar
    ) -> Date? {
        guard task.hasTimeRange, let endHour = task.endHour, let endMinute = task.endMinute else {
            return nil
        }
        return DailyTimeRange(
            startHour: task.hour,
            startMinute: task.minute,
            endHour: endHour,
            endMinute: endMinute
        ).activeOccurrenceStart(at: now, calendar: calendar)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([ScheduledTask].self, from: data)
        else { return }
        tasks = decoded
    }

    private func loadRangeState() {
        guard let raw = UserDefaults.standard.dictionary(forKey: Self.rangeStateKey) else { return }
        displayedRangeByDevice = raw.reduce(into: [:]) { result, item in
            if let value = item.value as? String, let id = UUID(uuidString: value) {
                result[item.key] = id
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    private func saveRangeState() {
        UserDefaults.standard.set(
            displayedRangeByDevice.mapValues(\.uuidString),
            forKey: Self.rangeStateKey
        )
    }

    private func saveDisplayOffState() {
        UserDefaults.standard.set(displayOffRangeDevices.sorted(), forKey: Self.displayOffStateKey)
    }
}
