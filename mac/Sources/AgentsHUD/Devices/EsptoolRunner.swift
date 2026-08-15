import Foundation
import AgentsHUDCore

/// Drives the bundled esptool binary. Encodes the ws175 board's known USB
/// quirk: long transfers drop the CDC port, so the app image is written in
/// chunks with per-chunk hash verification and retries (see esp32/README.md).
final class EsptoolRunner {
    struct Part {
        let offset: Int
        let url: URL
    }

    enum RunError: Error, LocalizedError {
        case esptoolMissing
        case flashFailed(String)

        var errorDescription: String? {
            switch self {
            case .esptoolMissing:
                return "应用内未打包 esptool（构建时缺少 Vendor/esptool），无法烧录"
            case let .flashFailed(msg):
                return msg
            }
        }
    }

    /// Progress: 0.0–1.0 plus a human-readable stage line.
    typealias Progress = @Sendable (Double, String) -> Void

    private let chip: String
    private let chunkBytes: Int
    private let before: String
    private let port: String

    init(board: BoardSpec, port: String) {
        chip = board.chip
        chunkBytes = board.flashChunkBytes
        before = board.esptoolBefore
        self.port = port
    }

    static func bundledEsptool() -> URL? {
        #if arch(arm64)
        let name = "esptool-arm64"
        #else
        let name = "esptool-x86_64"
        #endif
        // In the .app: Contents/Resources/esptool/<name>. In dev builds the
        // Vendor directory is used directly when present.
        if let url = Bundle.main.resourceURL?
            .appendingPathComponent("esptool").appendingPathComponent(name),
            FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        let dev = URL(fileURLWithPath: #filePath) // .../Sources/AgentsHUD/Devices/x.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/esptool").appendingPathComponent(name)
        if FileManager.default.isExecutableFile(atPath: dev.path) {
            return dev
        }
        return nil
    }

    /// Flash the given parts (bootloader/partition table go whole; the app
    /// image is split into chunks). Blocking — call from a background task.
    func flash(parts: [Part], progress: @escaping Progress) throws {
        guard let esptool = Self.bundledEsptool() else { throw RunError.esptoolMissing }

        // Boards without an auto-reset circuit (before == no_reset): ask the
        // running firmware to enter the ROM bootloader via the console 'b'
        // trick. Auto-reset boards let esptool toggle DTR/RTS itself.
        if before == "no_reset" {
            progress(0.02, "请求设备进入下载模式…")
            SerialPortLocator.requestDownloadMode(portPath: port)
            Thread.sleep(forTimeInterval: 1.5)
        } else {
            progress(0.02, "连接设备…")
        }

        // Probe the connection first. --after no_reset keeps the chip in the
        // bootloader — the default hard_reset would boot it back into the app
        // right before we try to write.
        _ = try run(esptool, ["--after", "no_reset", "flash_id"], allowFailure: false)

        // Build the write plan: whole small parts, chunked app image.
        var plan: [(offset: Int, file: URL, cleanup: Bool)] = []
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ahud-flash-\(ProcessInfo.processInfo.globallyUniqueString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        for part in parts {
            let attrs = try? FileManager.default.attributesOfItem(atPath: part.url.path)
            let size = attrs?[.size] as? Int ?? 0
            if size <= chunkBytes {
                plan.append((part.offset, part.url, false))
                continue
            }
            let data = try Data(contentsOf: part.url)
            var idx = 0
            var pos = 0
            while pos < data.count {
                let end = min(pos + chunkBytes, data.count)
                let chunk = data.subdata(in: pos..<end)
                let chunkURL = tmpDir.appendingPathComponent(
                    "\(part.url.lastPathComponent).\(idx)")
                try chunk.write(to: chunkURL)
                plan.append((part.offset + pos, chunkURL, true))
                pos = end
                idx += 1
            }
        }

        // Write each plan entry, verifying esptool's per-region hash line and
        // retrying pieces that die to the flaky USB port.
        for (i, entry) in plan.enumerated() {
            let frac = 0.05 + 0.9 * Double(i) / Double(plan.count)
            progress(frac, "写入 \(entry.file.lastPathComponent) @ 0x\(String(entry.offset, radix: 16))（\(i + 1)/\(plan.count)）")
            let isLast = i == plan.count - 1
            try writeRegion(esptool, offset: entry.offset, file: entry.file, hardResetAfter: isLast)
        }
        progress(1.0, "烧录完成，设备已重启")
    }

    private func writeRegion(_ esptool: URL, offset: Int, file: URL, hardResetAfter: Bool) throws {
        var lastError = ""
        for attempt in 1...3 {
            do {
                let out = try run(esptool, [
                    "--after", hardResetAfter ? "hard_reset" : "no_reset",
                    "write_flash", "0x\(String(offset, radix: 16))", file.path,
                ], allowFailure: false)
                if out.contains("Hash of data verified") {
                    return
                }
                lastError = "esptool 未确认数据校验（第 \(attempt) 次）"
            } catch {
                lastError = "\(error.localizedDescription)（第 \(attempt) 次）"
            }
            // The port may vanish for a moment after a failure; give it time.
            Thread.sleep(forTimeInterval: 2.0)
        }
        throw RunError.flashFailed("写入 0x\(String(offset, radix: 16)) 失败：\(lastError)。请重插 USB 后重试。")
    }

    @discardableResult
    private func run(_ esptool: URL, _ args: [String], allowFailure: Bool) throws -> String {
        let task = Process()
        task.executableURL = esptool
        task.arguments = [
            "--chip", chip,
            "--port", port,
            "--baud", "460800",
            "--before", before,
        ] + args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        if task.terminationStatus != 0 && !allowFailure {
            let tail = out.split(separator: "\n").suffix(4).joined(separator: "\n")
            throw RunError.flashFailed("esptool 退出码 \(task.terminationStatus)：\(tail)")
        }
        return out
    }
}
