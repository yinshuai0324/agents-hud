import SwiftUI
import AppKit

/// Palette tuned to the reference screenshot (deep navy background, vivid lamps).
/// Ported from `android/.../ui/theme/Theme.kt` so the Mac panel matches 1:1.
enum CC {
    static let bgTop = Color(hex: 0x0A0E1A)
    static let bgBottom = Color(hex: 0x05070D)
    static let card = Color.white.opacity(0.10)
    static let cardBorder = Color(hex: 0x1E2636)
    // Dark chip for status tags so bright colored text reads on the frosted glass.
    static let chip = Color.black.opacity(0.30)
    static let red = Color(hex: 0xFF453A)       // 出错 error
    static let orange = Color(hex: 0xFF9F0A)     // 审批 notify
    static let blue = Color(hex: 0x3B9EFF)       // 等候 waiting
    static let yellow = Color(hex: 0xFFC42E)     // 工作 working
    static let green = Color(hex: 0x34C759)      // 空闲 quiet
    // Translucent chips/tints — brand color at low alpha so they read as frosted
    // glass over the blurred backdrop rather than opaque blobs.
    static let redDim = Color(hex: 0xFF453A).opacity(0.22)
    static let yellowDim = Color(hex: 0xFFC42E).opacity(0.22)
    static let greenDim = Color(hex: 0x34C759).opacity(0.22)
    // White-based text tiers harmonize with any blurred background (vibrancy look).
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.60)
    static let textFaint = Color.white.opacity(0.40)
    static let track = Color.white.opacity(0.15)
}

/// The signal color for each session state. Single source of truth for the UI.
func stateColor(_ state: LightState) -> Color {
    switch state {
    case .error: return CC.red
    case .notify: return CC.orange
    case .waiting: return CC.blue
    case .working: return CC.yellow
    case .quiet: return CC.green
    }
}

/// Short Chinese label for each state.
func stateLabel(_ state: LightState) -> String {
    switch state {
    case .error: return "出错"
    case .notify: return "审批"
    case .waiting: return "等候"
    case .working: return "工作"
    case .quiet: return "空闲"
    }
}

/// AppKit color for the menu-bar dot (drawn into an NSImage).
func nsStateColor(_ state: LightState) -> NSColor {
    switch state {
    case .error: return NSColor(hex: 0xFF453A)
    case .notify: return NSColor(hex: 0xFF9F0A)
    case .waiting: return NSColor(hex: 0x3B9EFF)
    case .working: return NSColor(hex: 0xFFC42E)
    case .quiet: return NSColor(hex: 0x34C759)
    }
}

/// The menu-bar icon: a `sparkle` glyph in the menu-bar label color (auto
/// light/dark) with a small state-color dot badged in the bottom-right corner.
/// `dominant == nil` (disconnected) dims the sparkle and drops the dot. `dim`
/// fades the dot for the error/notify blink. Drawn via a scale-aware handler so
/// it stays crisp on Retina and recolors itself when the menu bar flips appearance.
func statusBarImage(dominant: LightState?, dim: Bool) -> NSImage {
    let size = NSSize(width: 18, height: 16)
    let image = NSImage(size: size, flipped: false) { _ in
        let symbolAlpha: CGFloat = dominant == nil ? 0.45 : 1.0
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if let sparkle = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "Agents-HUD")?
            .withSymbolConfiguration(cfg) {
            let s = sparkle.size
            let r = NSRect(x: 0, y: (size.height - s.height) / 2, width: s.width, height: s.height)
            sparkle.draw(in: r, from: .zero, operation: .sourceOver, fraction: symbolAlpha)
            // Recolor the (template) sparkle to the menu-bar label color.
            if let ctx = NSGraphicsContext.current {
                ctx.compositingOperation = .sourceAtop
                NSColor.labelColor.withAlphaComponent(symbolAlpha).setFill()
                NSBezierPath(rect: r).fill()
                ctx.compositingOperation = .sourceOver
            }
        }

        if let dom = dominant {
            let d: CGFloat = 7
            let badge = NSRect(x: size.width - d, y: 0, width: d, height: d)
            // Punch a transparent gap so the dot reads separately from the sparkle.
            if let ctx = NSGraphicsContext.current {
                ctx.compositingOperation = .clear
                NSBezierPath(ovalIn: badge.insetBy(dx: -1.2, dy: -1.2)).fill()
                ctx.compositingOperation = .sourceOver
            }
            nsStateColor(dom).withAlphaComponent(dim ? 0.4 : 1).setFill()
            NSBezierPath(ovalIn: badge).fill()
        }
        return true
    }
    image.isTemplate = false
    return image
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
