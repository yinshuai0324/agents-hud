import Foundation
import CryptoKit

/// Fetches firmware bundles from GitHub Releases and flashes them over USB.
/// Release assets are produced by .github/workflows/esp32.yml:
/// agents-hud-<ver>-esp32-<board>.zip containing .bin parts + manifest.json.
@MainActor
final class FirmwareUpdater: ObservableObject {
    static let repo = "yinshuai0324/agents-hud"

    struct Manifest: Decodable {
        struct Part: Decodable {
            let offset: String
            let file: String
            let sha256: String
        }
        let board: String
        let chip: String
        let version: String
        let parts: [Part]
    }

    enum Phase: Equatable {
        case idle
        case checking
        case available(version: String)
        case upToDate(version: String)
        case downloading
        case flashing(Double, String)
        case done
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    private var downloadURL: URL?
    private var latestVersion = ""

    /// Query the latest release for this board's asset.
    func checkLatest(board: BoardSpec, installedVersion: String?) async {
        phase = .checking
        do {
            let api = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
            var req = URLRequest(url: api)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  let assets = obj["assets"] as? [[String: Any]] else {
                phase = .failed("解析 GitHub Release 失败")
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let assetName = String(format: board.firmwareAsset, version)
            guard let asset = assets.first(where: { $0["name"] as? String == assetName }),
                  let urlStr = asset["browser_download_url"] as? String,
                  let url = URL(string: urlStr) else {
                phase = .failed("最新 Release (\(tag)) 没有 \(assetName)")
                return
            }
            downloadURL = url
            latestVersion = version
            if let installed = installedVersion, installed == version {
                phase = .upToDate(version: version)
            } else {
                phase = .available(version: version)
            }
        } catch {
            phase = .failed("检查更新失败：\(error.localizedDescription)")
        }
    }

    /// Download, verify, and flash to the given serial port.
    func flash(board: BoardSpec, port: String) async {
        guard let url = downloadURL else {
            phase = .failed("请先检查最新固件")
            return
        }
        phase = .downloading
        do {
            let (zipURL, _) = try await URLSession.shared.download(from: url)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("ahud-fw-\(latestVersion)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            // Unzip with the system tool (no third-party unzip dependency).
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzip.arguments = ["-o", "-q", zipURL.path, "-d", dir.path]
            try unzip.run()
            unzip.waitUntilExit()
            guard unzip.terminationStatus == 0 else {
                phase = .failed("解压固件包失败")
                return
            }

            let manifestURL = dir.appendingPathComponent("manifest.json")
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))

            // sha256 every part before touching the device.
            var parts: [EsptoolRunner.Part] = []
            for p in manifest.parts {
                let fileURL = dir.appendingPathComponent(p.file)
                let digest = SHA256.hash(data: try Data(contentsOf: fileURL))
                    .map { String(format: "%02x", $0) }.joined()
                guard digest == p.sha256 else {
                    phase = .failed("\(p.file) 校验失败（下载损坏？）")
                    return
                }
                guard let offset = Int(p.offset.dropFirst(2), radix: 16), p.offset.hasPrefix("0x") else {
                    phase = .failed("manifest offset 非法：\(p.offset)")
                    return
                }
                parts.append(EsptoolRunner.Part(offset: offset, url: fileURL))
            }

            let runner = EsptoolRunner(board: board, port: port)
            let partsToFlash = parts
            try await Task.detached(priority: .userInitiated) {
                try runner.flash(parts: partsToFlash) { frac, stage in
                    Task { @MainActor [weak self] in
                        self?.phase = .flashing(frac, stage)
                    }
                }
            }.value
            phase = .done
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
