import Foundation

/// Pairing payload rendered as a QR code for the Android app — port of qr.ts.
/// Field set `{v,url,token,name}` must stay byte-compatible with the existing
/// Android scanner.
public struct PairingPayload: Sendable {
    public let v = 1
    public let url: String // ws://ip:port
    public let token: String // shared secret, "" if disabled
    public let name: String // friendly host name shown in the app

    public func jsonString() -> String {
        CompactSnapshot.encodeOrdered([
            ("v", v),
            ("url", url),
            ("token", token),
            ("name", name),
        ])
    }
}

public enum Pairing {
    /// Pick the most likely LAN IPv4 address (private ranges, non-internal),
    /// same ranking as qr.ts lanIp().
    public static func lanIp() -> String {
        var candidates: [(addr: String, rank: Int)] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return "127.0.0.1" }
        defer { freeifaddrs(ifaddrPtr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            // Skip loopback (the "internal" check in Node).
            guard flags & IFF_LOOPBACK == 0, flags & IFF_UP != 0 else { continue }
            var addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let address = String(cString: buf)
            let name = String(cString: ifa.ifa_name)

            var rank = 0
            if address.hasPrefix("192.168.") { rank = 3 }
            else if address.hasPrefix("10.") { rank = 2 }
            else if address.hasPrefix("172.") { rank = 1 }
            if name == "en0" || name == "en1" || name.contains("wlan0") || name.contains("eth0") {
                rank += 1
            }
            candidates.append((address, rank))
        }
        candidates.sort { $0.rank > $1.rank }
        return candidates.first?.addr ?? "127.0.0.1"
    }

    public static func hostName() -> String {
        let raw = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return raw.replacingRegex("\\.local$", with: "")
    }

    public static func build(port: Int, token: String) -> PairingPayload {
        PairingPayload(url: "ws://\(lanIp()):\(port)", token: token, name: hostName())
    }
}
