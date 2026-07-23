import SwiftUI

/// The desktop app's main window: a sidebar (概览 / 设备 / 设置) over a shared
/// dark HUD theme. Replaces the menu-bar-only popover as the primary UI so the
/// app is a normal windowed application (Dock icon, ⌘Tab, resizable window).
struct MainView: View {
    @ObservedObject var client: SignalClient
    @ObservedObject var server: ServerController
    let provisioner: BLEProvisioner
    let serialProvisioner: SerialProvisioner
    let updater: FirmwareUpdater

    enum Section: String, CaseIterable, Identifiable {
        case devices = "设备"
        case settings = "设置"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .devices: return "display"
            case .settings: return "gearshape"
            }
        }
    }

    @State private var selection: Section = .devices

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 200)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            detail
                .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 520)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var detail: some View {
        switch selection {
        case .devices:
            DevicesView(
                provisioner: provisioner,
                serialProvisioner: serialProvisioner,
                server: server,
                updater: updater
            )
        case .settings:
            SettingsView(server: server, client: client)
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(serverColor)
                    .frame(width: 7, height: 7)
                Text(serverStatusText)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            Text("v\(ServerController.appVersion)")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    private var serverColor: Color {
        switch server.status {
        case .running: return CC.green
        case .starting, .stopped: return CC.yellow
        case .portConflict, .failed: return CC.red
        }
    }

    private var serverStatusText: String {
        switch server.status {
        case .running(let port): return "服务运行中 :\(port)"
        case .starting: return "服务启动中…"
        case .stopped: return "服务已停止"
        case .portConflict(let port): return "端口 \(port) 被占用"
        case .failed: return "服务启动失败"
        }
    }
}
