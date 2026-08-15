import SwiftUI
import AgentsHUDCore

/// Sends supported functions to a device that is already connected over WiFi.
/// Pairing and firmware stay in DevicesView; this page owns runtime controls.
struct FunctionsView: View {
    @ObservedObject var server: ServerController
    @State private var selectedDeviceID = ""

    private var onlineDevices: [DeviceInfo] {
        server.devices.filter(\.online)
    }

    private var selectedDevice: DeviceInfo? {
        onlineDevices.first { $0.id == selectedDeviceID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("设备功能")
                        .font(.title2.weight(.semibold))
                    Text("选择一台已通过 WiFi 连接的设备，然后下发功能。")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }

                usageSourcesCard

                if onlineDevices.isEmpty {
                    emptyState
                } else {
                    devicePicker
                    if let device = selectedDevice {
                        hardwareSummary(device)
                        capabilitySummary(device)
                        ControlPanel(device: device, server: server)
                            .id(device.id)
                    }
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(CC.bgBottom)
        .onAppear { ensureSelection() }
        .onChange(of: server.devices) { _ in ensureSelection() }
    }

    private var usageSourcesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("用量展示来源", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(CC.textPrimary)
                Spacer()
                Text("至少选择一个")
                    .font(.system(size: 11))
                    .foregroundColor(CC.textFaint)
            }
            Text("可单独或同时展示 Claude、Codex、Gemini；数据均来自本机记录。设备会跟随最近活跃的平台。")
                .font(.system(size: 12))
                .foregroundColor(CC.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                sourceToggle("claude", detail: "本地会话 + statusLine")
                sourceToggle("codex", detail: "本地 rollout 记录")
                sourceToggle("gemini", detail: "本地 CLI / Antigravity 记录")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CC.card)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(CC.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func sourceToggle(_ provider: String, detail: String) -> some View {
        let enabled = server.isUsageProviderEnabled(provider)
        return Toggle(isOn: Binding(
            get: { server.isUsageProviderEnabled(provider) },
            set: { server.setUsageProvider(provider, enabled: $0) }
        )) {
            HStack(spacing: 10) {
                ProviderIcon(provider: provider, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(providerDisplayName(provider))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(CC.textPrimary)
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundColor(CC.textFaint)
                }
            }
        }
        .toggleStyle(.switch)
        .disabled(enabled && !server.canDisableUsageProvider(provider))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CC.chip.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var devicePicker: some View {
        HStack(spacing: 12) {
            Text("目标设备")
                .font(.headline)
            Picker("目标设备", selection: $selectedDeviceID) {
                ForEach(onlineDevices) { device in
                    Text(deviceLabel(device)).tag(device.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 320)
            Spacer()
            Label("WiFi 在线", systemImage: "wifi")
                .font(.system(size: 11))
                .foregroundColor(.green)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("暂无在线设备")
                .font(.headline)
            Text("请先到“设备”页面完成配网，并等待设备通过 WiFi 连接。")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private func capabilitySummary(_ device: DeviceInfo) -> some View {
        HStack(spacing: 8) {
            Text("支持功能")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            ForEach(DeviceFeature.allCases.filter { device.supports($0) }, id: \.self) { feature in
                Label(feature.label, systemImage: feature.icon)
                    .font(.system(size: 10))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(CC.chip)
                    .clipShape(Capsule())
            }
            Spacer()
        }
    }

    private func hardwareSummary(_ device: DeviceInfo) -> some View {
        HStack(spacing: 8) {
            Text("设备形态")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            if let display = device.boardSpec?.display {
                Label(
                    display.shape == .round ? "圆形屏" : "方形屏",
                    systemImage: display.shape == .round ? "circle" : "square"
                )
                hardwareChip("\(display.width)×\(display.height)", icon: "rectangle.inset.filled")
            }
            hardwareChip(
                device.supports(.touch) ? "支持触摸" : "无触摸",
                icon: device.supports(.touch) ? "hand.tap" : "hand.raised.slash"
            )
            Spacer()
        }
        .font(.system(size: 10))
    }

    private func hardwareChip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(CC.chip)
            .clipShape(Capsule())
    }

    private func deviceLabel(_ device: DeviceInfo) -> String {
        let board = BoardRegistry.spec(for: device.board)?.displayName ?? device.board
        return "\(board) · \(device.id)"
    }

    private func ensureSelection() {
        guard !onlineDevices.contains(where: { $0.id == selectedDeviceID }) else { return }
        selectedDeviceID = onlineDevices.first?.id ?? ""
    }
}

private extension DeviceFeature {
    var label: String {
        switch self {
        case .usageSnapshot: return "用量概览"
        case .textCard: return "文字卡片"
        case .displayPower: return "屏幕电源"
        case .remoteAnimation: return "远程动画"
        }
    }

    var icon: String {
        switch self {
        case .usageSnapshot: return "chart.bar"
        case .textCard: return "text.alignleft"
        case .displayPower: return "display"
        case .remoteAnimation: return "photo.on.rectangle.angled"
        }
    }
}
