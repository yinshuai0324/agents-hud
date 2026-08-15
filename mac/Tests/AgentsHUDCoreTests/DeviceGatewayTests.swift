import XCTest
@testable import AgentsHUDCore

final class DeviceGatewayTests: XCTestCase {
    private final class FrameBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        func set(_ newValue: String) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func get() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testDirectedTextEscapesContentAndIncludesHold() throws {
        let gateway = DeviceGateway(hostName: "Test Mac")
        let frame = FrameBox()
        gateway.attach(id: "F232") { frame.set($0) }

        XCTAssertTrue(gateway.sendText(
            to: "F232",
            title: "say \"hi\"",
            body: "line 1\nline 2",
            holdSeconds: 30
        ))

        let data = try XCTUnwrap(frame.get()?.data(using: .utf8))
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(json["t"] as? String, "text")
        XCTAssertEqual(json["title"] as? String, "say \"hi\"")
        XCTAssertEqual(json["body"] as? String, "line 1\nline 2")
        XCTAssertEqual(json["hold"] as? Int, 30)
    }

    func testDirectedTextReturnsFalseForOfflineDevice() {
        let gateway = DeviceGateway()
        XCTAssertFalse(gateway.sendText(to: "offline", title: "", body: "hello"))
    }

    func testUsagePreferenceSurvivesReconnect() {
        let gateway = DeviceGateway()
        gateway.setUsageEnabled(false, id: "F232")
        gateway.upsert(id: "F232", board: "ws175", firmware: "0.2.0", address: "local")

        XCTAssertFalse(gateway.shouldPushUsage(id: "F232"))
        XCTAssertEqual(gateway.connectedDevices.first?.usageEnabled, false)

        gateway.setUsageEnabled(true, id: "F232")
        XCTAssertTrue(gateway.shouldPushUsage(id: "F232"))
        XCTAssertEqual(gateway.connectedDevices.first?.usageEnabled, true)
    }
}
