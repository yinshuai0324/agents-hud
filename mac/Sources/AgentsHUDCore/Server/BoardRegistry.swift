import Foundation

/// Runtime commands a device firmware explicitly understands.
public enum DeviceFeature: String, CaseIterable, Sendable, Hashable {
    case usageSnapshot
    case textCard
    case displayPower
    case remoteAnimation
}

public enum DisplayShape: String, Sendable, Hashable {
    case round
    case square
}

public enum DeviceInput: String, Sendable, Hashable {
    case touch
}

public struct DisplayProfile: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public let shape: DisplayShape

    public init(width: Int, height: Int, shape: DisplayShape) {
        self.width = width
        self.height = height
        self.shape = shape
    }
}

/// Everything the Mac and core command layer know about a supported board.
/// This is the single source of truth used by UI rendering, scheduled actions,
/// command validation, firmware lookup, and flashing behavior.
public struct BoardSpec: Sendable {
    public let id: String
    public let displayName: String
    public let chip: String
    public let firmwareAsset: String
    public let flashChunkBytes: Int
    public let esptoolBefore: String
    public let display: DisplayProfile
    public let inputs: Set<DeviceInput>
    public let features: Set<DeviceFeature>

    public init(
        id: String,
        displayName: String,
        chip: String,
        firmwareAsset: String,
        flashChunkBytes: Int,
        esptoolBefore: String,
        display: DisplayProfile,
        inputs: Set<DeviceInput>,
        features: Set<DeviceFeature>
    ) {
        self.id = id
        self.displayName = displayName
        self.chip = chip
        self.firmwareAsset = firmwareAsset
        self.flashChunkBytes = flashChunkBytes
        self.esptoolBefore = esptoolBefore
        self.display = display
        self.inputs = inputs
        self.features = features
    }
}

public enum BoardRegistry {
    public static let boards: [BoardSpec] = [
        BoardSpec(
            id: "ws175",
            displayName: "Waveshare 1.75\" 圆形 AMOLED",
            chip: "esp32s3",
            firmwareAsset: "agents-hud-%@-esp32-ws175.zip",
            flashChunkBytes: 364 * 1024,
            esptoolBefore: "no_reset",
            display: DisplayProfile(width: 466, height: 466, shape: .round),
            inputs: [.touch],
            features: [.usageSnapshot, .displayPower]
        ),
        BoardSpec(
            id: "sdd154",
            displayName: "小电视 1.54\" TFT (ESP8266)",
            chip: "esp8266",
            firmwareAsset: "agents-hud-%@-esp8266-sdd154.zip",
            flashChunkBytes: 4 * 1024 * 1024,
            esptoolBefore: "default_reset",
            display: DisplayProfile(width: 240, height: 240, shape: .square),
            inputs: [],
            features: [.usageSnapshot, .textCard, .displayPower]
        ),
    ]

    public static func spec(for id: String) -> BoardSpec? {
        boards.first { $0.id == id }
    }

    /// Unknown devices are allowed the baseline snapshot protocol only. New
    /// directed commands stay disabled until their board profile is declared.
    public static func features(for id: String) -> Set<DeviceFeature> {
        spec(for: id)?.features ?? [.usageSnapshot]
    }

    public static func supports(_ feature: DeviceFeature, board id: String) -> Bool {
        features(for: id).contains(feature)
    }

    public static var `default`: BoardSpec { boards[0] }
}

public extension DeviceInfo {
    var boardSpec: BoardSpec? { BoardRegistry.spec(for: board) }
    var features: Set<DeviceFeature> { BoardRegistry.features(for: board) }
    func supports(_ feature: DeviceFeature) -> Bool { features.contains(feature) }
    func supports(_ input: DeviceInput) -> Bool { boardSpec?.inputs.contains(input) == true }
}
