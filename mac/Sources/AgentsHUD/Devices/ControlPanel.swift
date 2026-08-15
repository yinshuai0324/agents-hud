import SwiftUI
import AgentsHUDCore

/// Per-device content controls: what the Mac pushes to a connected dial.
/// Usage snapshots stream by default; text cards send on demand; scheduled
/// tasks can fire at HH:mm or keep a text card visible for a daily time range.
struct ControlPanel: View {
    let device: DeviceInfo
    @ObservedObject var server: ServerController
    @ObservedObject private var scheduler = DeviceScheduler.shared
    @ObservedObject private var displayPower = DisplayPowerController.shared

    @State private var usageOn = true
    @State private var textTitle = ""
    @State private var textBody = ""
    @State private var holdSeconds = 10
    @State private var sentNote: String?
    @State private var showAddTask = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if device.supports(.usageSnapshot) {
                usageBlock
            }
            if device.supports(.usageSnapshot) && device.supports(.displayPower) {
                Divider().overlay(CC.cardBorder)
            }
            if device.supports(.displayPower) { displayPowerBlock }
            if (device.supports(.usageSnapshot) || device.supports(.displayPower))
                && device.supports(.textCard) {
                Divider().overlay(CC.cardBorder)
            }
            if device.supports(.textCard) {
                textBlock
            }
            if device.supports(.usageSnapshot) || device.supports(.displayPower)
                || device.supports(.textCard) {
                Divider().overlay(CC.cardBorder)
            }
            scheduleBlock
        }
        .padding(14)
        .background(CC.card)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CC.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { usageOn = device.usageEnabled }
    }

    // MARK: 屏幕电源

    private var displayPowerBlock: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("电脑锁屏联动").font(.system(size: 13, weight: .semibold))
                Text("Mac 锁屏时关闭设备屏幕，解锁后按定时策略恢复")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { displayPower.isLockScreenOffEnabled(for: device.id) },
                set: { displayPower.setLockScreenOff($0, deviceID: device.id) }
            ))
            .labelsHidden()
        }
    }

    // MARK: 用量概览

    private var usageBlock: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("用量概览").font(.system(size: 13, weight: .semibold))
                Text("默认内容：5h/7d 用量、状态、今日消耗，每 3 秒推送")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: $usageOn)
                .labelsHidden()
                .onChange(of: usageOn) { on in
                    server.deviceGateway.setUsageEnabled(on, id: device.id)
                }
        }
    }

    // MARK: 显示文字

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("显示文字").font(.system(size: 13, weight: .semibold))
            TextField("标题（可空）", text: $textTitle)
            TextField("正文", text: $textBody)
            HStack(spacing: 10) {
                Text("停留").font(.system(size: 12)).foregroundColor(.secondary)
                Picker("", selection: $holdSeconds) {
                    Text("常驻").tag(0)
                    Text("10 秒").tag(10)
                    Text("30 秒").tag(30)
                    Text("2 分钟").tag(120)
                }
                .labelsHidden()
                .frame(width: 90)
                Spacer()
                Button("发送到设备") { sendText() }
                    .disabled(textBody.isEmpty || !device.online)
            }
            if let note = sentNote {
                Text(note).font(.system(size: 11)).foregroundColor(.secondary)
            }
        }
    }

    private func sendText() {
        let ok = server.deviceGateway.sendText(
            to: device.id, title: textTitle, body: textBody, holdSeconds: holdSeconds
        )
        sentNote = ok
            ? "已发送 · \(holdSeconds == 0 ? "常驻显示" : "\(holdSeconds) 秒后回到用量")"
            : "发送失败：设备不在线"
    }

    // MARK: 定时任务

    private var scheduleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("定时任务").font(.system(size: 13, weight: .semibold))
                    Text("每天到点执行，或在指定时间段显示文字、关闭屏幕")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                Spacer()
                Button(showAddTask ? "收起" : "添加") { showAddTask.toggle() }
            }
            ForEach(scheduler.tasks(for: device.id)) { task in
                taskRow(task)
            }
            if showAddTask {
                AddTaskForm(device: device) { showAddTask = false }
            }
        }
    }

    private func taskRow(_ task: ScheduledTask) -> some View {
        let supported = task.action.isSupported(by: device)
        return HStack(spacing: 10) {
            Text(task.scheduleText)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .frame(minWidth: task.hasTimeRange ? 92 : 46, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.summary).font(.system(size: 12))
                if !supported {
                    Text("当前设备不支持此功能")
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                }
                if let note = scheduler.lastResult[task.id] {
                    Text(note).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { task.enabled },
                set: { scheduler.setEnabled($0, id: task.id) }
            ))
            .labelsHidden()
            .controlSize(.mini)
            .disabled(!supported)
            Button {
                scheduler.remove(task.id)
            } label: {
                Image(systemName: "trash").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .opacity(task.enabled && supported ? 1 : 0.5)
    }
}

/// Inline editor for a new scheduled task (time + action + optional text).
private struct AddTaskForm: View {
    private enum TextTiming: String, CaseIterable, Identifiable {
        case range
        case point

        var id: String { rawValue }
        var label: String { self == .range ? "时间段" : "到点停留" }
    }

    let device: DeviceInfo
    let onDone: () -> Void

    @State private var time = Calendar.current.date(
        bySettingHour: 9, minute: 0, second: 0, of: Date()
    ) ?? Date()
    @State private var endTime = Calendar.current.date(
        bySettingHour: 18, minute: 0, second: 0, of: Date()
    ) ?? Date()
    @State private var action: ScheduledTask.Action
    @State private var textTiming: TextTiming = .range
    @State private var textTitle = ""
    @State private var textBody = ""
    @State private var holdSeconds = 0

    private var supportedActions: [ScheduledTask.Action] {
        ScheduledTask.Action.allCases.filter { $0.isSupported(by: device) }
    }

    init(device: DeviceInfo, onDone: @escaping () -> Void) {
        self.device = device
        self.onDone = onDone
        _action = State(initialValue: device.supports(.textCard) ? .showText : .usageOn)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("", selection: $action) {
                    ForEach(supportedActions) { a in
                        Text(a.label).tag(a)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Spacer()
            }
            if action == .showText {
                Picker("显示方式", selection: $textTiming) {
                    ForEach(TextTiming.allCases) { timing in
                        Text(timing.label).tag(timing)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                HStack(spacing: 8) {
                    Text(textTiming == .range ? "开始" : "时间")
                        .font(.system(size: 12)).foregroundColor(.secondary)
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(width: 80)
                    if textTiming == .range {
                        Text("结束")
                            .font(.system(size: 12)).foregroundColor(.secondary)
                        DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .frame(width: 80)
                    }
                    Spacer()
                }
                TextField("标题（可空）", text: $textTitle)
                TextField("正文", text: $textBody)
                if textTiming == .point {
                    HStack(spacing: 10) {
                        Text("停留").font(.system(size: 12)).foregroundColor(.secondary)
                        Picker("", selection: $holdSeconds) {
                            Text("常驻").tag(0)
                            Text("10 秒").tag(10)
                            Text("30 秒").tag(30)
                            Text("2 分钟").tag(120)
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        Spacer()
                    }
                } else {
                    Text("到达结束时间后自动恢复用量页；结束早于开始时按跨午夜处理。")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            } else if action == .screenOff {
                HStack(spacing: 8) {
                    Text("开始").font(.system(size: 12)).foregroundColor(.secondary)
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(width: 80)
                    Text("结束").font(.system(size: 12)).foregroundColor(.secondary)
                    DatePicker("", selection: $endTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(width: 80)
                    Spacer()
                }
                Text("时段结束后自动亮屏；若 Mac 仍处于锁屏状态，则继续保持关屏。")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                HStack(spacing: 8) {
                    Text("时间").font(.system(size: 12)).foregroundColor(.secondary)
                    DatePicker("", selection: $time, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(width: 80)
                    Spacer()
                }
            }
            HStack {
                Spacer()
                Button("保存") { save() }
                    .disabled(!canSave)
            }
        }
        .padding(10)
        .background(CC.chip.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func save() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: time)
        let end = Calendar.current.dateComponents([.hour, .minute], from: endTime)
        let useRange = action == .screenOff || (action == .showText && textTiming == .range)
        DeviceScheduler.shared.add(ScheduledTask(
            deviceId: device.id,
            boardId: device.board,
            hour: comps.hour ?? 0,
            minute: comps.minute ?? 0,
            action: action,
            textTitle: textTitle,
            textBody: textBody,
            holdSeconds: useRange ? 0 : holdSeconds,
            endHour: useRange ? (end.hour ?? 0) : nil,
            endMinute: useRange ? (end.minute ?? 0) : nil
        ))
        onDone()
    }

    private var canSave: Bool {
        if action == .screenOff { return startAndEndDiffer }
        guard action == .showText else { return true }
        guard !textBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard textTiming == .range else { return true }
        return startAndEndDiffer
    }

    private var startAndEndDiffer: Bool {
        let start = Calendar.current.dateComponents([.hour, .minute], from: time)
        let end = Calendar.current.dateComponents([.hour, .minute], from: endTime)
        return start.hour != end.hour || start.minute != end.minute
    }
}
