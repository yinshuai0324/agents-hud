import Foundation
import IOKit
import IOKit.serial

/// Finds candidate USB serial ports for ESP32 dials and pokes a running
/// firmware into ROM download mode (the console_task 'b' command).
enum SerialPortLocator {
    struct Port: Identifiable, Equatable, Sendable {
        var id: String { path }
        let path: String // /dev/cu.usbmodemXXXX
        let usbVendorId: Int?
    }

    /// Espressif's USB VID (USB-Serial-JTAG). Other adapters still show up —
    /// they're just ranked below native ESP ports.
    static let espressifVID = 0x303A

    static func ports() -> [Port] {
        var result: [Port] = []
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching(kIOSerialBSDServiceValue)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let path = registryString(service, kIOCalloutDeviceKey) else { continue }
            guard path.contains("usb") else { continue } // skip bluetooth/pty
            let vid = usbProperty(service, "idVendor")
            result.append(Port(path: path, usbVendorId: vid))
        }
        // Native ESP32 USB first, then other USB serial adapters.
        return result.sorted {
            ($0.usbVendorId == espressifVID ? 0 : 1, $0.path)
                < ($1.usbVendorId == espressifVID ? 0 : 1, $1.path)
        }
    }

    /// Send 'b' to a running firmware so it reboots into the ROM bootloader
    /// (esp32/main/main.c console_task). Best-effort: a device already in the
    /// bootloader ignores it.
    static func requestDownloadMode(portPath: String) {
        let fd = open(portPath, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var tio = termios()
        if tcgetattr(fd, &tio) == 0 {
            cfmakeraw(&tio)
            cfsetspeed(&tio, speed_t(B115200))
            tcsetattr(fd, TCSANOW, &tio)
        }
        _ = "b".withCString { write(fd, $0, 1) }
        // Give the firmware a moment to see it before the port disappears.
        usleep(300_000)
    }

    private static func registryString(_ service: io_object_t, _ key: String) -> String? {
        guard let cf = IORegistryEntryCreateCFProperty(
            service, key as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return cf.takeRetainedValue() as? String
    }

    /// Walk up the registry to find the USB device's vendor id.
    private static func usbProperty(_ service: io_object_t, _ key: String) -> Int? {
        var current = service
        IOObjectRetain(current)
        defer { IOObjectRelease(current) }
        for _ in 0..<6 {
            if let cf = IORegistryEntryCreateCFProperty(
                current, key as CFString, kCFAllocatorDefault, 0
            ), let n = cf.takeRetainedValue() as? Int {
                return n
            }
            var parent: io_object_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS else {
                return nil
            }
            IOObjectRelease(current)
            current = parent
        }
        return nil
    }
}
