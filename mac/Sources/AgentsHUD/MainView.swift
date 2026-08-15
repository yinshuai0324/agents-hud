import SwiftUI
import AppKit

@MainActor
final class MainNavigation: ObservableObject {
    @Published var selection: MainView.Section? = .devices
}

/// The desktop app's main window: genuine macOS Finder-style sidebar
/// (设备 / 功能 / 设置) using the system's native sidebar Source List.
struct MainView: View {
    private let sidebarWidth: CGFloat = 175

    @ObservedObject var client: SignalClient
    @ObservedObject var server: ServerController
    let provisioner: BLEProvisioner
    let serialProvisioner: SerialProvisioner
    let updater: FirmwareUpdater
    @ObservedObject var navigation: MainNavigation

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case devices = "设备"
        case functions = "功能"
        case settings = "设置"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .devices: return "display"
            case .functions: return "square.grid.2x2"
            case .settings: return "gearshape"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.white
                    .ignoresSafeArea()

                List(selection: $navigation.selection) {
                    ForEach(Section.allCases) { section in
                        Label(section.rawValue, systemImage: section.icon)
                            .tag(section)
                    }
                }
                .listStyle(.sidebar)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                .sidebarContentMarginsIfAvailable()
                .padding(.horizontal, 6)
                .safeAreaInset(edge: .bottom) {
                    ServerStatusFooter(server: server, client: client)
                }
            }
            .frame(width: sidebarWidth)
            .frame(maxHeight: .infinity)
            .clipped()
            .background {
                Color.white
                    .ignoresSafeArea()
            }

            Rectangle()
                .fill(CC.separator)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .background {
                    CC.separator
                        .ignoresSafeArea()
                }

            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 680, minHeight: 480)
    }

    @ViewBuilder private var detail: some View {
        switch navigation.selection ?? .devices {
        case .devices:
            DevicesView(
                provisioner: provisioner,
                serialProvisioner: serialProvisioner,
                server: server,
                updater: updater
            )
        case .functions:
            FunctionsView(server: server)
        case .settings:
            SettingsView(server: server, client: client)
        }
    }
}

/// Sidebar bottom status footer.
private struct ServerStatusFooter: View {
    @ObservedObject var server: ServerController
    @ObservedObject var client: SignalClient

    var body: some View {
        VStack(alignment: .center, spacing: 3) {
            Divider()
                .overlay(CC.separator)
                .padding(.bottom, 6)

            HStack(spacing: 6) {
                Circle()
                    .fill(serverColor)
                    .frame(width: 7, height: 7)
                Text(serverStatusText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Text("v\(ServerController.appVersion)")
                .font(.system(size: 10))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var serverColor: Color {
        if isClientConnected { return CC.green }
        switch server.status {
        case .running: return CC.green
        case .starting, .stopped: return CC.yellow
        case .portConflict, .failed: return CC.red
        }
    }

    private var serverStatusText: String {
        if isClientConnected { return "服务运行中" }
        switch server.status {
        case .running: return "服务运行中"
        case .starting: return "服务启动中…"
        case .stopped: return "服务已停止"
        case .portConflict: return "端口被占用"
        case .failed: return "服务启动失败"
        }
    }

    private var isClientConnected: Bool {
        if case .connected = client.connection { return true }
        return false
    }
}

private extension View {
    @ViewBuilder
    func removingSidebarToggleIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            toolbar(removing: .sidebarToggle)
        } else {
            self
        }
    }

    @ViewBuilder
    func sidebarContentMarginsIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            contentMargins(.horizontal, 12, for: .scrollContent)
                .contentMargins(.top, 8, for: .scrollContent)
        } else {
            self
        }
    }
}
