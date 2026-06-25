import SwiftUI

// MARK: - Formatting (ported from UsageBar.kt / SessionList.kt)

func fmtTokens(_ t: Int64) -> String {
    if t >= 1_000_000 { return String(format: "%.1fM", Double(t) / 1_000_000) }
    if t >= 1_000 { return String(format: "%.1fk", Double(t) / 1_000) }
    return "\(t)"
}

func fmtRate(_ t: Int64) -> String {
    if t >= 1_000 { return String(format: "%.1fk", Double(t) / 1_000) }
    return "\(t)"
}

func fmtUsd(_ v: Double) -> String {
    v >= 100 ? "$" + String(format: "%.0f", v) : "$" + String(format: "%.2f", v)
}

func remainingText(_ minutes: Int) -> String {
    if minutes <= 0 { return "已刷新" }
    let h = minutes / 60, m = minutes % 60
    return h > 0 ? "\(h) 小时 \(m) 分后刷新" : "\(m) 分后刷新"
}

func relativeTime(_ epochMs: Int64, now: Date) -> String {
    if epochMs <= 0 { return "" }
    let mins = Int((now.timeIntervalSince1970 * 1000 - Double(epochMs)) / 60_000)
    if mins < 1 { return "刚刚" }
    if mins < 60 { return "\(mins) 分前" }
    if mins < 60 * 24 { return "\(mins / 60) 小时前" }
    return "\(mins / (60 * 24)) 天前"
}

/// Relative "X 前" from a snapshot ISO timestamp; "" if unparseable.
func lastUpdatedLabel(_ ts: String, now: Date) -> String {
    guard !ts.isEmpty else { return "" }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = withFraction.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
    guard let date else { return "" }
    let mins = Int(now.timeIntervalSince(date) / 60)
    if mins < 1 { return "刚刚" }
    if mins < 60 { return "\(mins) 分钟前" }
    if mins < 60 * 24 { return "\(mins / 60) 小时前" }
    return "\(mins / (60 * 24)) 天前"
}

// MARK: - Small views

/// A rounded tag, like the plan / live badges in UsageBar.kt.
struct Pill: View {
    let text: String
    var fg: Color = CC.textPrimary
    var bg: Color = CC.card
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(fg)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// One usage gauge: "5 小时 · 25%" + reset countdown + a colored progress bar.
struct UsageRow: View {
    let label: String
    let percent: Int
    let resetMin: Int
    let big: Bool

    var body: some View {
        let pct = min(max(percent, 0), 100)
        let barColor: Color = pct >= 85 ? CC.red : (pct >= 60 ? CC.yellow : CC.green)
        VStack(spacing: 7) {
            HStack {
                Text("\(label) · \(pct)%")
                    .font(.system(size: big ? 15 : 12, weight: .semibold))
                    .foregroundColor(CC.textPrimary)
                Spacer()
                Text(remainingText(resetMin))
                    .font(.system(size: big ? 12 : 11, weight: .medium))
                    .foregroundColor(CC.textSecondary)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(CC.track)
                    Capsule().fill(barColor)
                        .frame(width: max(0, g.size.width * CGFloat(pct) / 100))
                }
            }
            .frame(height: 7)
        }
    }
}

/// Fixed per-state tally row: 审批 · 工作 · 等候 · 空闲 · 出错 (ported from Counters.kt).
struct CountersRow: View {
    let counts: [LightState: Int]
    private let order: [LightState] = [.notify, .working, .waiting, .quiet, .error]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(order, id: \.self) { st in
                let c = counts[st] ?? 0
                VStack(spacing: 1) {
                    Text("\(c)")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(c > 0 ? stateColor(st) : CC.textFaint)
                    Text(stateLabel(st))
                        .font(.system(size: 11))
                        .foregroundColor(c > 0 ? CC.textSecondary : CC.textFaint)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

/// One session card (ported from SessionList.kt's SessionRow).
struct SessionRow: View {
    let session: Session
    let now: Date

    var body: some View {
        let st = LightState.from(session.state)
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(st == .quiet ? stateColor(st).opacity(0.55) : stateColor(st))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.project.isEmpty ? "…" : session.project)
                    .font(.system(size: 13))
                    .foregroundColor(CC.textPrimary)
                    .lineLimit(1)
                if let meta = metaLine() {
                    Text(meta).font(.system(size: 10)).foregroundColor(CC.textFaint).lineLimit(1)
                }
                if let lead = leadLine(st) {
                    Text(lead.0).font(.system(size: 10)).foregroundColor(lead.1).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(relativeTime(session.lastActivity, now: now))
                .font(.system(size: 13))
                .foregroundColor(CC.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(CC.card.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func metaLine() -> String? {
        var parts: [String] = []
        if session.tokens > 0 { parts.append(fmtTokens(session.tokens) + " tokens") }
        if session.contextTokens > 0 {
            parts.append("上下文 \(fmtTokens(session.contextTokens)) · 剩 \(session.contextLeftPercent)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The live tool while working, else the states that need you (出错/审批).
    private func leadLine(_ st: LightState) -> (String, Color)? {
        if st == .working, !session.currentTool.isEmpty {
            return (session.currentTool, stateColor(.working))
        }
        if st == .error || st == .notify {
            return (stateLabel(st), stateColor(st))
        }
        return nil
    }
}
