import SwiftUI
import AppKit
import AgentsHUDCore

/// Device management window: provisions over BLE or USB, then communicates
/// with connected devices over WiFi. Firmware update actions live here too.
struct DevicesView: View {
    @ObservedObject var provisioner: BLEProvisioner
    @ObservedObject var serialProvisioner: SerialProvisioner
    @ObservedObject var server: ServerController
    @ObservedObject var updater: FirmwareUpdater

    private enum ProvisioningTarget: Hashable {
        case bluetooth(UUID)
        case usb(String)
    }

    @State private var showingProvisioning = false
    @State private var selectedTarget: ProvisioningTarget?
    @State private var ssid: String = ""
    @State private var password: String = ""
    @State private var serialPorts: [SerialPortLocator.Port] = []
    @State private var selectedPort: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                connectedSection
                Divider().overlay(CC.cardBorder)
                addDeviceSection
                Divider().overlay(CC.cardBorder)
                firmwareSection
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(CC.bgBottom)
        .onAppear {
            refreshPortsInBackground()
            loadCurrentSSID()
        }
        .sheet(isPresented: $showingProvisioning) {
            provisioningSheet
        }
    }

    // MARK: - Connected over WiFi + control

    private var connectedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已连接设备").font(.headline)
            if server.devices.isEmpty {
                Text("暂无设备通过 WiFi 连接（先在下方配网）")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            } else {
                ForEach(server.devices) { dev in
                    deviceRow(dev)
                }
            }
        }
    }

    private func deviceRow(_ dev: DeviceInfo) -> some View {
        return HStack {
            Image(systemName: "circle.fill")
                .font(.system(size: 8))
                .foregroundColor(dev.online ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(BoardRegistry.spec(for: dev.board)?.displayName ?? dev.board) · \(dev.id)")
                    .font(.system(size: 13, weight: .medium))
                Text("固件 v\(dev.firmware) · \(dev.address)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text(dev.online ? "WiFi 已连接" : "已离线")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(CC.card)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(CC.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Unified provisioning discovery

    private var addDeviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("添加新设备").font(.headline)
                Spacer()
                Button("配网") {
                    showingProvisioning = true
                }
                .keyboardShortcut("n", modifiers: [.command])
            }
            Text("自动扫描附近的 ESP32，并识别通过 USB 连接的 ESP8266；配网完成后统一使用 WiFi 通信。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    private var provisioningSheet: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("发现设备")
                        .font(.title2.weight(.semibold))
                    Text("正在同时扫描蓝牙设备和 USB 串口设备")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("关闭") {
                    showingProvisioning = false
                }
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !provisioner.bluetoothOn {
                        Label("蓝牙未开启，仍会继续扫描 USB 设备", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12))
                            .foregroundColor(.orange)
                    }

                    discoverySummary

                    ForEach(provisioner.devices) { device in
                        bluetoothDiscoveryRow(device)
                    }

                    ForEach(serialProvisioner.discoveredDevices) { device in
                        usbDiscoveryRow(device)
                    }

                    if selectedTarget != nil {
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("WiFi 配置")
                                .font(.headline)
                            TextField("WiFi 名称（2.4GHz）", text: $ssid)
                            SecureField("WiFi 密码", text: $password)
                            selectedProvisioningStatus
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Button("重新扫描") {
                    restartDiscovery()
                }
                .disabled(provisioningBusy)
                Spacer()
                Button("下发 WiFi 配置") {
                    beginProvisioning()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selectedTarget == nil || ssid.isEmpty || provisioningBusy)
            }
            .padding(20)
        }
        .frame(width: 520, height: 480)
        .onAppear {
            startDiscovery()
            loadCurrentSSID()
        }
        .onDisappear {
            stopProvisioningFlow()
            refreshPortsInBackground()
        }
    }

    @ViewBuilder
    private var discoverySummary: some View {
        if provisioner.devices.isEmpty && serialProvisioner.discoveredDevices.isEmpty {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("等待发现设备…")
                        .font(.system(size: 13, weight: .medium))
                    Text("请让 ESP32 进入配网模式，或用数据线连接 ESP8266")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)
        } else {
            Label(
                "已发现 \(provisioner.devices.count + serialProvisioner.discoveredDevices.count) 台设备",
                systemImage: "checkmark.circle"
            )
            .font(.system(size: 12))
            .foregroundColor(.secondary)
        }
    }

    private func bluetoothDiscoveryRow(_ device: BLEProvisioner.Discovered) -> some View {
        let target = ProvisioningTarget.bluetooth(device.id)
        let selected = selectedTarget == target
        return HStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .frame(width: 20)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .medium))
                Text(bluetoothDeviceDetail(device))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Text("\(device.rssi) dBm")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selected ? .accentColor : .secondary)
        }
        .padding(10)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTarget = target
        }
    }

    private func usbDiscoveryRow(_ device: SerialProvisioner.DiscoveredDevice) -> some View {
        let target = ProvisioningTarget.usb(device.portPath)
        let selected = selectedTarget == target
        return HStack(spacing: 10) {
            Image(systemName: "cable.connector")
                .frame(width: 20)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(BoardRegistry.spec(for: device.board)?.displayName ?? device.board)
                    .font(.system(size: 13, weight: .medium))
                Text("USB · \(device.deviceId) · 固件 v\(device.firmware)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(selected ? .accentColor : .secondary)
        }
        .padding(10)
        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedTarget = target
        }
    }

    private func bluetoothDeviceDetail(_ device: BLEProvisioner.Discovered) -> String {
        if device.board.isEmpty {
            return "蓝牙 · ESP32"
        }
        return "蓝牙 · \(BoardRegistry.spec(for: device.board)?.displayName ?? device.board) · 固件 v\(device.firmware)"
    }

    @ViewBuilder
    private var selectedProvisioningStatus: some View {
        switch selectedTarget {
        case .bluetooth:
            bluetoothPhaseLabel
        case .usb:
            serialPhaseLabel
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var bluetoothPhaseLabel: some View {
        switch provisioner.phase {
        case .idle, .scanning:
            EmptyView()
        case .connecting:
            progress("连接设备中…")
        case .readingInfo:
            progress("读取设备信息…")
        case .sending:
            progress("下发 WiFi 配置…")
        case let .deviceStatus(status, ip):
            progress(statusText(status, ip: ip))
        case let .done(ip):
            successLabel(ip: ip)
        case let .failed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.system(size: 12))
        }
    }

    @ViewBuilder
    private var serialPhaseLabel: some View {
        switch serialProvisioner.phase {
        case .idle:
            EmptyView()
        case .opening:
            progress("打开串口…")
        case .probing:
            progress("识别设备…")
        case .sending:
            progress("下发 WiFi 配置…")
        case let .deviceStatus(status, ip):
            progress(statusText(status, ip: ip))
        case let .done(ip):
            successLabel(ip: ip)
        case let .failed(message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundColor(.red)
                .font(.system(size: 12))
        }
    }

    private func successLabel(ip: String) -> some View {
        Label(
            ip.isEmpty ? "配网成功，设备已通过 WiFi 连接" : "配网成功（\(ip)），设备已通过 WiFi 连接",
            systemImage: "checkmark.circle.fill"
        )
        .foregroundColor(.green)
        .font(.system(size: 12))
    }

    private var bluetoothBusy: Bool {
        switch provisioner.phase {
        case .connecting, .readingInfo, .sending, .deviceStatus:
            return true
        default:
            return false
        }
    }

    private var serialBusy: Bool {
        switch serialProvisioner.phase {
        case .opening, .probing, .sending, .deviceStatus:
            return true
        default:
            return false
        }
    }

    private var provisioningBusy: Bool {
        bluetoothBusy || serialBusy
    }

    private func startDiscovery() {
        selectedTarget = nil
        provisioner.startScan()
        serialProvisioner.startDiscovery()
    }

    private func restartDiscovery() {
        provisioner.stop()
        serialProvisioner.stopDiscovery()
        serialProvisioner.cancel()
        startDiscovery()
    }

    private func beginProvisioning() {
        guard let selectedTarget else { return }
        serialProvisioner.stopDiscovery()
        switch selectedTarget {
        case let .bluetooth(id):
            guard let device = provisioner.devices.first(where: { $0.id == id }) else { return }
            serialProvisioner.cancel()
            provisioner.provision(
                device,
                ssid: ssid,
                password: password,
                payloadFrom: server
            )
        case let .usb(portPath):
            provisioner.stop()
            serialProvisioner.provision(
                portPath: portPath,
                ssid: ssid,
                password: password,
                payloadFrom: server
            )
        }
    }

    private func stopProvisioningFlow() {
        provisioner.stop()
        serialProvisioner.stopDiscovery()
        serialProvisioner.cancel()
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 12)).foregroundColor(.secondary)
        }
    }

    private func statusText(_ status: String, ip: String) -> String {
        switch status {
        case "connecting": return "设备正在连接 WiFi…"
        case "got_ip": return "已获取 IP \(ip)，正在连接本机服务…"
        default: return "设备状态：\(status)"
        }
    }

    // MARK: - Firmware update (USB)

    private var firmwareSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("固件更新（USB）").font(.headline)
                Spacer()
                Button("刷新串口") { refreshPortsInBackground() }
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

    private func refreshPortsInBackground() {
        Task.detached(priority: .utility) {
            let ports = SerialPortLocator.ports()
            await MainActor.run { applyPorts(ports) }
        }
    }

    private func applyPorts(_ ports: [SerialPortLocator.Port]) {
        serialPorts = ports
        if selectedPort.isEmpty || !serialPorts.contains(where: { $0.path == selectedPort }) {
            selectedPort = serialPorts.first?.path ?? ""
        }
    }

    private func loadCurrentSSID() {
        guard ssid.isEmpty else { return }
        Task.detached(priority: .utility) {
            let detected = DevicesView.currentSSID()
            await MainActor.run {
                if ssid.isEmpty { ssid = detected ?? "" }
            }
        }
    }

    /// Current WiFi SSID as a convenient default (needs Location permission on
    /// newer macOS; empty when unavailable).
    nonisolated static func currentSSID() -> String? {
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
    private let serialProvisioner = SerialProvisioner()
    private let updater = FirmwareUpdater()

    func show(server: ServerController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DevicesView(
            provisioner: provisioner, serialProvisioner: serialProvisioner,
            server: server, updater: updater
        )
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
