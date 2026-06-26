import Foundation
import UserNotifications

/// Posts a macOS notification when a session enters an attention state
/// (轮到你 / 审批 / 出错). Only works from a real .app bundle (not `swift run`),
/// which is how we ship — guarded so dev runs don't crash.
@MainActor
final class Notifier {
    static let shared = Notifier()
    private var available = false

    /// Master on/off, toggled from the status-item right-click menu. Default on.
    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "notificationsEnabled") }
    }

    func setup() {
        guard Bundle.main.bundleIdentifier != nil else { return } // skip in `swift run`
        available = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Notify that `state` was just entered by a session. No-op for states that
    /// don't need attention, when disabled, or when not bundled.
    func sessionEntered(state: String, project: String, cwd: String) {
        guard available, enabled else { return }
        let copy: (title: String, detail: String)
        switch LightState.from(state) {
        case .waiting: copy = ("✅ 轮到你了", "完成一轮")
        case .notify:  copy = ("⏳ 等待审批", "在等你批准操作")
        case .error:   copy = ("❌ 运行出错", "运行中止了")
        default: return
        }

        let name = project.isEmpty ? (cwd.split(separator: "/").last.map(String.init) ?? "会话") : project
        let content = UNMutableNotificationContent()
        content.title = copy.title
        content.body = "「\(name)」\(copy.detail)"
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
