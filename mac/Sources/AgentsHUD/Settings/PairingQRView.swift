import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins
import AgentsHUDCore

/// Renders the Android pairing QR in a window (replaces the terminal QR from
/// `agents-hud connect`). Payload format is unchanged: {v,url,token,name}.
struct PairingQRView: View {
    let payload: PairingPayload

    var body: some View {
        VStack(spacing: 14) {
            Text("用手机 App 扫码连接")
                .font(.headline)
            if let image = Self.qrImage(payload.jsonString()) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 220, height: 220)
                    .background(Color.white)
                    .cornerRadius(8)
            } else {
                Text("二维码生成失败").foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("WebSocket", value: payload.url)
                LabeledContent("主机", value: payload.name)
                LabeledContent("鉴权", value: payload.token.isEmpty ? "未启用" : "已启用 (token)")
            }
            .font(.system(size: 12))
            .frame(maxWidth: 260)
        }
        .padding(24)
    }

    static func qrImage(_ string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Simple window host for the pairing QR (kept alive by the AppDelegate).
@MainActor
final class PairingWindowController {
    private var window: NSWindow?

    func show(payload: PairingPayload) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: PairingQRView(payload: payload))
        let window = NSWindow(contentViewController: hosting)
        window.title = "连接手机"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
