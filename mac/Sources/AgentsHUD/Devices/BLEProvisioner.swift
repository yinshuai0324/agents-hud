import Foundation
import CoreBluetooth
import AgentsHUDCore

/// CoreBluetooth central that provisions an ESP32 dial: scan → connect →
/// read device info → write WiFi credentials + server URL → follow status
/// notifications until the device reports a working server link.
///
/// GATT contract (esp32/main/provision_ble.c):
///   service 41485544-...0001, write cfg ...0003, status notify ...0004,
///   device info ...0005.
@MainActor
final class BLEProvisioner: NSObject, ObservableObject {
    nonisolated static let serviceUUID = CBUUID(string: "41485544-6469-616C-2D64-617461000001")
    nonisolated static let cfgUUID = CBUUID(string: "41485544-6469-616C-2D64-617461000003")
    nonisolated static let statusUUID = CBUUID(string: "41485544-6469-616C-2D64-617461000004")
    nonisolated static let infoUUID = CBUUID(string: "41485544-6469-616C-2D64-617461000005")

    struct Discovered: Identifiable {
        let id: UUID
        var name: String
        var rssi: Int
        /// Filled after connecting and reading the info characteristic.
        var deviceId: String = ""
        var board: String = ""
        var firmware: String = ""
    }

    enum Phase: Equatable {
        case idle
        case scanning
        case connecting
        case readingInfo
        case sending
        /// Raw `st` values from the device: connecting/got_ip/ws_ok/bad_pass/
        /// ap_not_found/server_fail.
        case deviceStatus(String, ip: String)
        case done(ip: String)
        case failed(String)
    }

    @Published private(set) var bluetoothOn = false
    @Published private(set) var devices: [Discovered] = []
    @Published private(set) var phase: Phase = .idle

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var cfgChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private var pendingConfig: Data?
    private var lastIp = ""

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        devices = []
        phase = .scanning
        guard central.state == .poweredOn else { return }
        // The 128-bit service UUID sits in the scan response; filtering by
        // service works and skips unrelated peripherals.
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false,
        ])
    }

    func stop() {
        central.stopScan()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        phase = .idle
    }

    /// Connect and send the provisioning payload to the chosen device.
    func provision(_ device: Discovered, ssid: String, password: String, payloadFrom controller: ServerController) {
        guard let p = knownPeripherals[device.id] else {
            phase = .failed("设备已不可见，请重新扫描")
            return
        }
        let pairing = controller.pairingPayload
        let json = CompactSnapshot.encodeOrdered([
            ("v", 1),
            ("ssid", ssid),
            ("pw", password),
            ("url", pairing.url),
            ("token", pairing.token),
            ("name", pairing.name),
        ])
        pendingConfig = Data(json.utf8)
        phase = .connecting
        central.stopScan()
        peripheral = p
        p.delegate = self
        central.connect(p)
    }

    private var knownPeripherals: [UUID: CBPeripheral] = [:]
}

extension BLEProvisioner: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.bluetoothOn = central.state == .poweredOn
            if central.state == .poweredOn, self.phase == .scanning {
                self.startScan()
            } else if central.state == .unauthorized {
                self.phase = .failed("蓝牙权限被拒绝，请在系统设置中允许")
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "AgentsHUD"
        let id = peripheral.identifier
        let rssi = RSSI.intValue
        Task { @MainActor in
            self.knownPeripherals[id] = peripheral
            if let idx = self.devices.firstIndex(where: { $0.id == id }) {
                self.devices[idx].name = name
                self.devices[idx].rssi = rssi
            } else {
                self.devices.append(Discovered(id: id, name: name, rssi: rssi))
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.phase = .readingInfo
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.phase = .failed("连接失败：\(error?.localizedDescription ?? "未知错误")")
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            // Expected after ws_ok (the device shuts BLE down); only surface
            // an error when we were still mid-flight.
            switch self.phase {
            case .done, .failed, .idle:
                break
            case .deviceStatus(let st, let ip) where st == "ws_ok":
                self.phase = .done(ip: ip)
            default:
                self.phase = .failed("设备断开了连接")
            }
            self.peripheral = nil
        }
    }
}

extension BLEProvisioner: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            Task { @MainActor in self.phase = .failed("设备缺少配网服务（固件太旧？）") }
            return
        }
        peripheral.discoverCharacteristics([Self.cfgUUID, Self.statusUUID, Self.infoUUID], for: svc)
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let chars = service.characteristics ?? []
        let cfg = chars.first { $0.uuid == Self.cfgUUID }
        let status = chars.first { $0.uuid == Self.statusUUID }
        let info = chars.first { $0.uuid == Self.infoUUID }
        Task { @MainActor in
            guard let cfg else {
                self.phase = .failed("设备缺少配网特征（固件太旧，请先用 USB 升级固件）")
                return
            }
            self.cfgChar = cfg
            self.statusChar = status
            if let status { peripheral.setNotifyValue(true, for: status) }
            if let info { peripheral.readValue(for: info) }
            // Write straight away; info arrival just enriches the UI.
            if let payload = self.pendingConfig {
                self.phase = .sending
                peripheral.writeValue(payload, for: cfg, type: .withResponse)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error {
                self.phase = .failed("下发配置失败：\(error.localizedDescription)")
            } else if characteristic.uuid == Self.cfgUUID {
                self.phase = .deviceStatus("connecting", ip: "")
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let uuid = characteristic.uuid
        Task { @MainActor in
            if uuid == Self.infoUUID {
                let devId = obj["id"] as? String ?? ""
                let board = obj["board"] as? String ?? ""
                let fw = obj["fw"] as? String ?? ""
                if let idx = self.devices.firstIndex(where: { $0.id == peripheral.identifier }) {
                    self.devices[idx].deviceId = devId
                    self.devices[idx].board = board
                    self.devices[idx].firmware = fw
                }
            } else if uuid == Self.statusUUID {
                let st = obj["st"] as? String ?? ""
                let ip = obj["ip"] as? String ?? ""
                if !ip.isEmpty { self.lastIp = ip }
                switch st {
                case "ws_ok":
                    self.phase = .done(ip: self.lastIp)
                    // Device lingers ~10s then drops BLE; disconnect eagerly.
                    if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
                case "bad_pass":
                    self.phase = .failed("WiFi 密码错误")
                case "ap_not_found":
                    self.phase = .failed("找不到该 WiFi（确认 2.4GHz 且在范围内）")
                case "server_fail":
                    self.phase = .failed("设备已连上 WiFi（\(self.lastIp)），但连不上本机服务，请检查防火墙/局域网权限")
                default:
                    self.phase = .deviceStatus(st, ip: ip)
                }
            }
        }
    }
}
