import Foundation

/// Everything the Mac app needs to know about a supported board model.
/// New ESP32 variants get a row here plus a board_<id> component in esp32/.
struct BoardSpec {
    /// Stable id, matches board_id() in the firmware, e.g. "ws175".
    let id: String
    /// Human-readable name shown in the device UI.
    let displayName: String
    /// esptool chip argument.
    let chip: String
    /// GitHub release asset name pattern; %@ = version.
    let firmwareAsset: String
    /// USB serial chunked-write size that survives this board's flaky CDC
    /// (esp32/README.md: the 1.75" board drops the port on long transfers).
    let flashChunkBytes: Int
}

enum BoardRegistry {
    static let boards: [BoardSpec] = [
        BoardSpec(
            id: "ws175",
            displayName: "Waveshare 1.75\" 圆形 AMOLED",
            chip: "esp32s3",
            firmwareAsset: "agents-hud-%@-esp32-ws175.zip",
            flashChunkBytes: 364 * 1024
        ),
    ]

    static func spec(for id: String) -> BoardSpec? {
        boards.first { $0.id == id }
    }

    /// Fallback for devices that predate board-id reporting.
    static var `default`: BoardSpec { boards[0] }
}
