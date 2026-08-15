import SwiftUI
import AppKit
import AgentsHUDCore

/// Settings tab: embedded server status, Claude Code hooks, phone pairing QR,
/// and app updates.
struct SettingsView: View {
    @ObservedObject var server: ServerController
    @ObservedObject var client: SignalClient

    @State private var hooksInstalled = false
    @State private var hookMessage: String?
    @State private var showPairing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                serverCard
                hooksCard
                pairingCard
                updatesCard
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(CC.bgBottom)
        .onAppear { hooksInstalled = server.hooksInstalled }
    }

    // MARK: Server

    private var serverCard: some View {
        card("数据服务") {
            infoRow("状态", serverStatusText)
            infoRow("端口", "\(server.config.port)")
            infoRow("鉴权", server.config.authToken.isEmpty ? "未启用" : "已启用（token）")
            if case .portConflict = server.status {
                Text(ServerController.brewConflictHint)
                    .font(.system(size: 12)).foregroundColor(CC.yellow)
                    .fixedSize(horizontal: false, vertical: true)
                Button("已停止旧服务，重试") { server.retryAfterConflict() }
            }
        }
    }

    private var serverStatusText: String {
        if case .connected = client.connection {
            return "运行中 :\(server.config.port)"
        }
        switch server.status {
        case .running(let p): return "运行中 :\(p)"
        case .starting: return "启动中…"
        case .stopped: return "已停止"
        case .portConflict(let p): return "端口 \(p) 被占用"
        case .failed(let m): return "失败：\(m)"
        }
    }

    // MARK: Hooks

    private var hooksCard: some View {
        card("Claude Code 钩子") {
            Text("装上后状态最准最实时，并能拿到官方用量、上下文剩余、当前模型、实时工具调用。")
                .font(.system(size: 12)).foregroundColor(CC.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(hooksInstalled ? "重新安装钩子" : "安装钩子") { installHooks() }
                if hooksInstalled {
                    Button("卸载") { uninstallHooks() }
                }
                Spacer()
                Text(hooksInstalled ? "已安装" : "未安装")
                    .font(.system(size: 12))
                    .foregroundColor(hooksInstalled ? CC.green : CC.textFaint)
            }
            if let msg = hookMessage {
                Text(msg).font(.system(size: 11)).foregroundColor(CC.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("装完请重启正在运行的 Claude Code 会话。")
                .font(.system(size: 11)).foregroundColor(CC.textFaint)
        }
    }

    private func installHooks() {
        do {
            let r = try server.installHooks()
            hooksInstalled = true
            hookMessage = "已写入 \(r.settingsPath)" + (r.statuslineWarning.map { "\n\($0)" } ?? "")
        } catch {
            hookMessage = "安装失败：\(error.localizedDescription)"
        }
    }

    private func uninstallHooks() {
        do {
            try server.uninstallHooks()
            hooksInstalled = false
            hookMessage = "已移除钩子与 statusLine。"
        } catch {
            hookMessage = "卸载失败：\(error.localizedDescription)"
        }
    }

    // MARK: Pairing

    private var pairingCard: some View {
        card("连接手机") {
            Text("手机 App 扫码即可在同一局域网连接看板。")
                .font(.system(size: 12)).foregroundColor(CC.textSecondary)
            if showPairing {
                let payload = server.pairingPayload
                if let img = PairingQRView.qrImage(payload.jsonString()) {
                    Image(nsImage: img)
                        .interpolation(.none).resizable()
                        .frame(width: 180, height: 180)
                        .background(Color.white).cornerRadius(8)
                }
                infoRow("地址", payload.url)
                infoRow("主机", payload.name)
            }
            Button(showPairing ? "隐藏二维码" : "显示配对二维码") {
                showPairing.toggle()
            }
        }
    }

    // MARK: Updates

    private var updatesCard: some View {
        card("应用更新") {
            infoRow("当前版本", "v\(ServerController.appVersion)")
            if UpdaterController.shared.isAvailable {
                Button("检查更新…") { UpdaterController.shared.checkForUpdates() }
            } else {
                Text("此构建未启用自动更新（缺少 Sparkle 公钥）。")
                    .font(.system(size: 11)).foregroundColor(CC.textFaint)
            }
        }
    }

    // MARK: Helpers

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(CC.textPrimary)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CC.card)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(CC.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.system(size: 13)).foregroundColor(CC.textSecondary)
            Spacer()
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundColor(CC.textPrimary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
