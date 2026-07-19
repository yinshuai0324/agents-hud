import Foundation

/// Publishes _agentshud._tcp over Bonjour so devices can rediscover the server
/// when the Mac's IP changes. The SRV record carries the real server port and
/// the TXT record the host name (devices prefer the host they were provisioned
/// against) plus the server version.
///
/// NetService is deprecated but is the only Foundation API that can advertise
/// a port owned by another socket (FlyingFox holds the listener); NWListener
/// can only advertise sockets it created itself.
public final class BonjourAdvertiser: NSObject, @unchecked Sendable {
    private var service: NetService?

    public func start(port: Int, hostName: String, version: String) {
        stop()
        let service = NetService(
            domain: "local.",
            type: "_agentshud._tcp.",
            name: "AgentsHUD @ \(hostName)",
            port: Int32(port)
        )
        let txt: [String: Data] = [
            "name": Data(hostName.utf8),
            "ver": Data(version.utf8),
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: txt))
        service.publish()
        self.service = service
    }

    public func stop() {
        service?.stop()
        service = nil
    }
}
