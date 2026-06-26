import SwiftUI
import AppKit

/// The macOS app icon, drawn in SwiftUI so it regenerates from source. A deep
/// navy "squircle" with a glowing sparkle — matching the menu-bar glyph and the
/// frosted panel. Rendered to a 1024² PNG via `--render-icon`, then `make-icon.sh`
/// turns it into AppIcon.icns.
struct AppIconView: View {
    private let radius: CGFloat = 186 // ~macOS continuous-squircle radius at 824pt

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hex: 0x20305A), Color(hex: 0x070A14)],
                    startPoint: .top, endPoint: .bottom))

            RadialGradient(
                colors: [Color(hex: 0x3B9EFF).opacity(0.45), .clear],
                center: .center, startRadius: 10, endRadius: 470)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))

            Image(systemName: "sparkle")
                .font(.system(size: 500, weight: .regular))
                .foregroundStyle(LinearGradient(
                    colors: [.white, Color(hex: 0xCFE3FF)],
                    startPoint: .top, endPoint: .bottom))
                .shadow(color: Color(hex: 0x3B9EFF).opacity(0.7), radius: 50)

            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.22), .clear],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 3)
        }
        .frame(width: 824, height: 824)
        .shadow(color: .black.opacity(0.33), radius: 28, y: 16)
        .frame(width: 1024, height: 1024)
    }
}

/// Dev-only: `Agents-HUD --render-icon [out.png]` renders the 1024² icon master.
@MainActor
func runRenderIconIfRequested() -> Bool {
    guard let i = CommandLine.arguments.firstIndex(of: "--render-icon") else { return false }
    let out = (i + 1 < CommandLine.arguments.count)
        ? CommandLine.arguments[i + 1]
        : NSTemporaryDirectory() + "agentshud-icon.png"

    let renderer = ImageRenderer(content: AppIconView().frame(width: 1024, height: 1024))
    renderer.scale = 1
    if let image = renderer.nsImage,
       let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: out))
        FileHandle.standardError.write("icon: \(out)\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
    }
    exit(0)
}
