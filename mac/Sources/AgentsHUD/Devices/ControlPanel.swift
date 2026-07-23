import SwiftUI
import AgentsHUDCore

/// Per-device content controls: what the Mac pushes to a connected dial.
/// Usage snapshots stream by default; text cards send on demand. Animation and
/// scheduled tasks are staged here and land in later iterations.
struct ControlPanel: View {
    let device: DeviceInfo
    @ObservedObject var server: ServerController

    @State private var usageOn = true
    @State private var textTitle = ""
    @State private var textBody = ""
    @State private var holdSeconds = 10
    @State private var sentNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            usageBlock
            Divider().overlay(CC.cardBorder)
            textBlock
            Divider().overlay(CC.cardBorder)
            comingSoonBlock
        }
        .padding(14)
        .background(CC.card)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(CC.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onAppear { usageOn = device.usageEnabled }
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

    // MARK: 动画 / 定时任务（后续）

    private var comingSoonBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            comingRow(icon: "photo.on.rectangle.angled", title: "动画", desc: "下发像素动画资源（开发中）")
            comingRow(icon: "clock.arrow.circlepath", title: "定时任务", desc: "按时间切换显示内容（开发中）")
        }
    }

    private func comingRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(desc).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Text("开发中").font(.system(size: 10))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(CC.chip).clipShape(Capsule())
                .foregroundColor(.secondary)
        }
        .opacity(0.7)
    }
}
