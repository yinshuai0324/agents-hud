import Foundation
import Combine
import AgentsHUDCore

/// A per-device scheduled action: at HH:mm every day, push a text card or flip
/// the usage stream. Persisted to UserDefaults so schedules survive restarts.
struct ScheduledTask: Codable, Identifiable, Equatable {
    enum Action: String, Codable, CaseIterable, Identifiable {
        case showText
        case usageOn
        case usageOff

        var id: String { rawValue }
        var label: String {
            switch self {
            case .showText: return "显示文字"
            case .usageOn: return "开启用量推送"
            case .usageOff: return "关闭用量推送"
            }
        }
    }

    var id: UUID = UUID()
    var deviceId: String
    var hour: Int
    var minute: Int
    var enabled: Bool = true
    var action: Action
    // Only meaningful for .showText.
    var textTitle: String = ""
    var textBody: String = ""
    var holdSeconds: Int = 0

    var timeText: String { String(format: "%02d:%02d", hour, minute) }

    var summary: String {
        switch action {
        case .showText:
            let hold = holdSeconds == 0 ? "常驻" : "\(holdSeconds) 秒"
            return "显示「\(textBody)」· \(hold)"
        case .usageOn: return action.label
        case .usageOff: return action.label
        }
    }
}

/// Owns the schedule list and fires due tasks against the device gateway.
/// Checks every 20s; a task fires at most once per minute-of-day (daily repeat).
@MainActor
final class DeviceScheduler: ObservableObject {
    static let shared = DeviceScheduler()

    @Published private(set) var tasks: [ScheduledTask] = []
    /// Last fire outcome per task id, for UI feedback ("已发送" / "设备不在线").
    @Published private(set) var lastResult: [UUID: String] = [:]

    private static let defaultsKey = "scheduledTasks"
    private var timer: Timer?
    /// Minute keys ("yyyyMMdd HH:mm" + task id) already fired, so the 20s tick
    /// doesn't re-fire within the same minute.
    private var fired: Set<String> = []

    private init() {
        load()
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
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        lastResult[id] = nil
        save()
    }

    func setEnabled(_ enabled: Bool, id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].enabled = enabled
        save()
    }

    // MARK: - Firing

    private func tick() {
        let now = Date()
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        guard let hour = comps.hour, let minute = comps.minute else { return }
        let dayKey = "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0) \(hour):\(minute)"

        for task in tasks where task.enabled && task.hour == hour && task.minute == minute {
            let key = "\(dayKey)#\(task.id.uuidString)"
            guard !fired.contains(key) else { continue }
            fired.insert(key)
            perform(task)
        }
        // Keep the fired set from growing forever: entries older than the
        // current minute can never match again.
        if fired.count > 512 {
            fired = fired.filter { $0.hasPrefix(dayKey) }
        }
    }

    private func perform(_ task: ScheduledTask) {
        let gateway = ServerController.shared.deviceGateway
        switch task.action {
        case .showText:
            let ok = gateway.sendText(
                to: task.deviceId,
                title: task.textTitle,
                body: task.textBody,
                holdSeconds: task.holdSeconds
            )
            lastResult[task.id] = ok ? "已发送" : "上次触发时设备不在线"
        case .usageOn:
            gateway.setUsageEnabled(true, id: task.deviceId)
            lastResult[task.id] = "已开启"
        case .usageOff:
            gateway.setUsageEnabled(false, id: task.deviceId)
            lastResult[task.id] = "已关闭"
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([ScheduledTask].self, from: data)
        else { return }
        tasks = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}
