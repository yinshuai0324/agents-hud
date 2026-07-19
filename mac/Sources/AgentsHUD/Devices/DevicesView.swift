import SwiftUI
import AppKit
import AgentsHUDCore

/// Device management window: BLE provisioning wizard on top, currently
/// connected (WiFi) dials below. Firmware update actions live here too.
struct DevicesView: View {
    @ObservedObject var provisioner: BLEProvisioner
    @ObservedObject var server: ServerController
    @ObservedObject var updater: FirmwareUpdater

    @State private var selectedDevice: BLEProvisioner.Discovered?
    @State private var ssid: String = DevicesView.currentSSID() ?? ""
    @State private var password: String = ""
    @State private var serialPorts: [SerialPortLocator.Port] = []
    @State private var selectedPort: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectedSection
            Divider()
            provisionSection
            Divider()
            firmwareSection
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { refreshPorts() }
    }

    // MARK: - Connected over WiFi

    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("已连接设备").font(.headline)
            if server.devices.isEmpty {
                Text("暂无设备通过 WiFi 连接")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(server.devices) { dev in
                    HStack {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(BoardRegistry.spec(for: dev.board)?.displayName ?? dev.board) · \(dev.id)")
                                .font(.system(size: 13, weight: .medium))
                            Text("固件 v\(dev.firmware) · \(dev.address)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - BLE provisioning

    private var provisionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("添加新设备").font(.headline)
                Spacer()
                Button(provisioner.phase == .scanning ? "扫描中…" : "扫描") {
                    provisioner.startScan()
                }
                .disabled(provisioner.phase == .scanning || !provisioner.bluetoothOn)
            }

            if !provisioner.bluetoothOn {
                Label("蓝牙未开启", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundColor(.orange)
            }

            if provisioner.devices.isEmpty && provisioner.phase == .scanning {
                Text("正在寻找 AgentsHUD 设备…（设备需处于「等待配对」状态）")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            ForEach(provisioner.devices) { dev in
                HStack {
                    Image(systemName: selectedDevice?.id == dev.id
                        ? "largecircle.fill.circle" : "circle")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(dev.name).font(.system(size: 13, weight: .medium))
                        if !dev.board.isEmpty {
                            Text("\(dev.board) · v\(dev.firmware)")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(dev.rssi) dBm")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedDevice = dev }
            }

            if selectedDevice != nil {
                TextField("WiFi 名称（2.4GHz）", text: $ssid)
                SecureField("WiFi 密码", text: $password)
                HStack {
                    Button("下发配置") {
                        if let dev = selectedDevice {
                            provisioner.provision(dev, ssid: ssid, password: password, payloadFrom: server)
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(ssid.isEmpty || !phaseAllowsSend)
                    Spacer()
                }
            }

            phaseLabel
        }
    }

    private var phaseAllowsSend: Bool {
        switch provisioner.phase {
        case .idle, .scanning, .failed, .done: return true
        default: return false
        }
    }

    @ViewBuilder
    private var phaseLabel: some View {
        switch provisioner.phase {
        case .idle, .scanning:
            EmptyView()
        case .connecting:
            progress("连接设备中…")
        case .readingInfo:
            progress("读取设备信息…")
        case .sending:
            progress("下发 WiFi 配置…")
        case let .deviceStatus(st, ip):
            progress(statusText(st, ip: ip))
        case let .done(ip):
            Label(ip.isEmpty ? "配网成功，设备已连上服务" : "配网成功（\(ip)），设备已连上服务",
                  systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 12))
        case let .failed(msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.system(size: 12))
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private func statusText(_ st: String, ip: String) -> String {
        switch st {
        case "connecting": return "设备正在连接 WiFi…"
        case "got_ip": return "已获取 IP \(ip)，正在连接本机服务…"
        default: return "设备状态：\(st)"
        }
    }

    // MARK: - Firmware update (USB)

    private var firmwareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("固件更新（USB）").font(.headline)
                Spacer()
                Button("刷新串口") { refreshPorts() }
            }

            if serialPorts.isEmpty {
                Text("未发现 USB 串口，请用数据线连接设备")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            } else {
                Picker("串口", selection: $selectedPort) {
                    ForEach(serialPorts) { port in
                        Text(port.path).tag(port.path)
                    }
                }
                .pickerStyle(.menu)
            }

            HStack {
                Button("检查最新固件") {
                    let board = currentBoard
                    let installed = server.devices.first?.firmware
                    Task { await updater.checkLatest(board: board, installedVersion: installed) }
                }
                .disabled(updater.phase == .checking || updater.phase == .downloading)
                if case .available(let v) = updater.phase {
                    Button("烧录 v\(v)") {
                        let board = currentBoard
                        let port = selectedPort
                        Task { await updater.flash(board: board, port: port) }
                    }
                    .disabled(selectedPort.isEmpty)
                }
                Spacer()
            }

            firmwarePhaseLabel
        }
    }

    /// Board of the first connected device; single-model default otherwise.
    private var currentBoard: BoardSpec {
        if let dev = server.devices.first, let spec = BoardRegistry.spec(for: dev.board) {
            return spec
        }
        return BoardRegistry.default
    }

    @ViewBuilder
    private var firmwarePhaseLabel: some View {
        switch updater.phase {
        case .idle:
            EmptyView()
        case .checking:
            progress("检查最新固件…")
        case let .available(version):
            Text("有新固件 v\(version) 可用").font(.system(size: 12)).foregroundColor(.orange)
        case let .upToDate(version):
            Text("已是最新（v\(version)）").font(.system(size: 12)).foregroundColor(.secondary)
        case .downloading:
            progress("下载固件包…")
        case let .flashing(frac, stage):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: frac)
                Text(stage).font(.system(size: 11)).foregroundColor(.secondary)
            }
        case .done:
            Label("固件烧录完成，设备已重启", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green).font(.system(size: 12))
        case let .failed(msg):
            Label(msg, systemImage: "xmark.circle.fill")
                .foregroundColor(.red).font(.system(size: 12))
        }
    }

    private func refreshPorts() {
        serialPorts = SerialPortLocator.ports()
        if selectedPort.isEmpty || !serialPorts.contains(where: { $0.path == selectedPort }) {
            selectedPort = serialPorts.first?.path ?? ""
        }
    }

    /// Current WiFi SSID as a convenient default (needs Location permission on
    /// newer macOS; empty when unavailable).
    static func currentSSID() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        task.arguments = ["-getairportnetwork", "en0"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        task.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let range = out.range(of: ": ") else { return nil }
        let ssid = out[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return ssid.isEmpty ? nil : ssid
    }
}

/// Window host for the devices UI.
@MainActor
final class DevicesWindowController {
    private var window: NSWindow?
    private let provisioner = BLEProvisioner()
    private let updater = FirmwareUpdater()

    func show(server: ServerController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DevicesView(provisioner: provisioner, server: server, updater: updater)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = "设备"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
