import SwiftUI
import AppKit

/// The pop-over panel shown when the menu-bar icon is clicked. A compact,
/// vertical mirror of the Android DashboardScreen.
struct PanelView: View {
    @ObservedObject var client: SignalClient
    /// Render the scrim alone (no live blur) so it can be composited over a
    /// sample wallpaper in the offscreen render test.
    var previewBackground = false

    var body: some View {
        let connected = client.connection == .connected
        let dataOpacity = connected ? 1.0 : 0.35
        VStack(alignment: .leading, spacing: 10) {
            header(connected: connected)

            usageSection
                .opacity(dataOpacity)
        }
        .padding(14)
        .frame(width: 360)
        .background(backgroundLayer)
    }

    @ViewBuilder private var backgroundLayer: some View {
        if previewBackground {
            panelScrim
        } else {
            VisualEffectBackground().overlay(panelScrim)
        }
    }

    /// A thin dark wash over the frosted glass — just enough to anchor the white
    /// text, while staying translucent so the blurred desktop shows through.
    private var panelScrim: some View {
        LinearGradient(
            colors: [CC.bgTop.opacity(0.20), CC.bgBottom.opacity(0.32)],
            startPoint: .top, endPoint: .bottom
        )
    }

    // MARK: Header

    private func header(connected: Bool) -> some View {
        let stale = connected ? "" : lastUpdatedLabel(client.snapshot?.ts ?? "", now: client.now)
        return HStack(spacing: 8) {
            Circle()
                .fill(client.dominant.map(stateColor) ?? CC.textFaint.opacity(0.4))
                .frame(width: 9, height: 9)
            connectionTag
            if !stale.isEmpty {
                Text("更新于 \(stale)").font(.system(size: 9)).foregroundColor(CC.textFaint)
            }
            Spacer()
        }
    }

    private var connectionTag: some View {
        let spec: (String, Color)
        switch client.connection {
        case .connected: spec = ("已连接", CC.green)
        case .connecting: spec = ("连接中", CC.yellow)
        case .disconnected: spec = ("已断开", CC.red)
        }
        return Text(spec.0)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(spec.1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(CC.chip)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: Usage section (ported from UsageBar.kt)

    private var usageSection: some View {
        let snap = client.snapshot
        let live = snap?.usage5h.source == "live"
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("您的套餐信息").font(.system(size: 13, weight: .medium)).foregroundColor(CC.textSecondary)
                if let plan = snap?.plan, !plan.isEmpty { Pill(text: plan) }
                Spacer()
                Pill(
                    text: live ? "实时" : "等待上报",
                    fg: live ? CC.green : CC.textFaint,
                    bg: CC.chip
                )
            }

            if live, let u = snap?.usage5h {
                UsageRow(label: "5 小时", percent: u.percent, resetMin: u.resetInMinutes, big: true)
                    .padding(.top, 10)
                if let w = snap?.usage7d {
                    UsageRow(label: "7 天", percent: w.percent, resetMin: w.resetInMinutes, big: false)
                        .padding(.top, 10)
                }
            } else {
                Text("5 小时 / 7 天用量 · 等待 statusLine 上报…")
                    .font(.system(size: 13)).foregroundColor(CC.textFaint).padding(.top, 10)
            }

            if let model = snap?.model, !model.isEmpty {
                infoRow(title: "当前模型", value: model).padding(.top, 16)
            }
            if let today = snap?.today, today.tokens > 0 || today.cacheWriteTokens > 0 {
                infoRow(title: "今日消耗", value: todayText(today)).padding(.top, 8)
            }
            let speed = speedText(snap)
            if !speed.isEmpty {
                infoRow(title: "速度", value: speed).padding(.top, 8)
            }
        }
    }

    private func infoRow(title: String, value: String) -> some View {
        HStack {
            Text(title).font(.system(size: 13)).foregroundColor(CC.textSecondary)
            Spacer()
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundColor(CC.textPrimary)
        }
    }

    private func todayText(_ t: TodayUsage) -> String {
        var s = fmtTokens(t.tokens) + " tokens"
        if t.cacheWriteTokens > 0 { s += " +" + fmtTokens(t.cacheWriteTokens) + " 缓存" }
        s += " · " + fmtUsd(t.costUSD)
        return s
    }

    private func speedText(_ snap: Snapshot?) -> String {
        var parts: [String] = []
        if let b = snap?.usage5h.burnRatePerMin, b > 0 { parts.append("燃烧 \(fmtRate(b))/分") }
        if let o = snap?.outputTokensPerSec, o > 0 { parts.append("生成 \(o) tok/s") }
        return parts.joined(separator: " · ")
    }

    // MARK: Footer + settings

}

/// Frosted-glass backdrop: blurs the desktop behind the pop-over (a dark HUD
/// material), with a faint navy tint laid over it for brand + text contrast.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        // Lock to dark so the frosted glass stays dark on a light desktop,
        // keeping the light HUD text readable.
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.appearance = NSAppearance(named: .darkAqua)
    }
}
