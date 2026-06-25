import SwiftUI
import AppKit

/// Dev-only: `Agents-HUD --render-test [out.png]` fetches the live snapshot from
/// the local server and renders the panel to a PNG, then exits. Lets us verify
/// the layout headlessly (the menu-bar popover can't be screenshotted from CLI).
@MainActor
func runRenderTestIfRequested() -> Bool {
    guard CommandLine.arguments.contains("--render-test") else { return false }

    let outPath = CommandLine.arguments.dropFirst()
        .first(where: { !$0.hasPrefix("--") })
        ?? NSTemporaryDirectory() + "agentshud-panel.png"

    let client = SignalClient.shared
    if let url = URL(string: "http://127.0.0.1:4317/api/snapshot"),
       let data = try? Data(contentsOf: url),
       let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
        client.snapshot = snap
    }
    client.connection = .connected
    client.now = Date()

    // Float the panel (scrim-only, no live blur) over a colorful "wallpaper" so
    // the translucency and white-text harmony are visible offscreen. The real
    // app additionally blurs the desktop, which only softens contrast further.
    let preview = ZStack {
        LinearGradient(
            colors: [Color(hex: 0x2E5C9A), Color(hex: 0x7A4FA3), Color(hex: 0xC2683C)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        .frame(width: 540, height: 480)
        PanelView(client: client, previewBackground: true)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 22, y: 8)
    }
    let renderer = ImageRenderer(content: preview)
    renderer.scale = 2
    if let nsImage = renderer.nsImage,
       let tiff = nsImage.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: outPath))
        FileHandle.standardError.write("rendered: \(outPath)\n".data(using: .utf8)!)
    } else {
        FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
    }
    exit(0)
}
