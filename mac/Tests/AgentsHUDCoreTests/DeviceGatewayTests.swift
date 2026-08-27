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
        gateway.upsert(id: "F232", board: "sdd154", firmware: "0.1.18", address: "local")
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

    func testClearTextSendsExplicitDismissCommand() throws {
        let gateway = DeviceGateway()
        let frame = FrameBox()
        gateway.upsert(id: "F232", board: "sdd154", firmware: "0.1.18", address: "local")
        gateway.attach(id: "F232") { frame.set($0) }

        XCTAssertTrue(gateway.clearText(on: "F232"))
        let data = try XCTUnwrap(frame.get()?.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["t"] as? String, "text")
        XCTAssertEqual(json["clear"] as? Bool, true)
        XCTAssertEqual(json["hold"] as? Int, 1)
    }

    func testUsagePreferenceSurvivesReconnect() {
        let gateway = DeviceGateway()
        gateway.upsert(id: "F232", board: "ws175", firmware: "0.2.0", address: "local")
        gateway.setUsageEnabled(false, id: "F232")
        gateway.upsert(id: "F232", board: "ws175", firmware: "0.2.0", address: "local")

        XCTAssertFalse(gateway.shouldPushUsage(id: "F232"))
        XCTAssertEqual(gateway.connectedDevices.first?.usageEnabled, false)

        gateway.setUsageEnabled(true, id: "F232")
        XCTAssertTrue(gateway.shouldPushUsage(id: "F232"))
        XCTAssertEqual(gateway.connectedDevices.first?.usageEnabled, true)
    }

    func testOldConnectionCannotMarkReplacementOffline() {
        let gateway = DeviceGateway()
        let oldFrame = FrameBox()
        let newFrame = FrameBox()
        gateway.upsert(id: "F232", board: "ws175", firmware: "0.2.0", address: "local")

        let oldConnection = gateway.attach(id: "F232") { oldFrame.set($0) }
        let newConnection = gateway.attach(id: "F232") { newFrame.set($0) }
        gateway.upsert(id: "F232", board: "ws175", firmware: "0.2.0", address: "local")

        gateway.detach(id: "F232", connectionID: oldConnection)
        XCTAssertEqual(gateway.connectedDevices.first?.online, true)
        XCTAssertTrue(gateway.send(to: "F232", "replacement"))
        XCTAssertNil(oldFrame.get())
        XCTAssertEqual(newFrame.get(), "replacement")

        gateway.detach(id: "F232", connectionID: newConnection)
        XCTAssertEqual(gateway.connectedDevices.first?.online, false)
        XCTAssertFalse(gateway.send(to: "F232", "offline"))
    }

    func testDisplayPowerCommandIsDirectedAndValidated() throws {
        let gateway = DeviceGateway()
        let frame = FrameBox()
        gateway.upsert(id: "F232", board: "ws175", firmware: "0.2.0", address: "local")
        gateway.attach(id: "F232") { frame.set($0) }

        XCTAssertTrue(gateway.setDisplayPower(false, id: "F232"))
        let data = try XCTUnwrap(frame.get()?.data(using: .utf8))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["t"] as? String, "display")
        XCTAssertEqual(json["on"] as? Bool, false)
        XCTAssertFalse(gateway.setDisplayPower(false, id: "unknown"))
    }

    func testTextIsRejectedWhenBoardDoesNotSupportIt() {
        let gateway = DeviceGateway()
        let frame = FrameBox()
        gateway.upsert(id: "F232", board: "ws175", firmware: "0.1.18", address: "local")
        gateway.attach(id: "F232") { frame.set($0) }

        XCTAssertFalse(gateway.sendText(to: "F232", title: "", body: "unsupported"))
        XCTAssertNil(frame.get())
    }

    func testBoardCapabilitiesMatchFirmwareProtocols() {
        XCTAssertTrue(BoardRegistry.supports(.usageSnapshot, board: "ws175"))
        XCTAssertTrue(BoardRegistry.supports(.displayPower, board: "ws175"))
        XCTAssertFalse(BoardRegistry.supports(.textCard, board: "ws175"))

        XCTAssertTrue(BoardRegistry.supports(.usageSnapshot, board: "sdd154"))
        XCTAssertTrue(BoardRegistry.supports(.textCard, board: "sdd154"))
        XCTAssertTrue(BoardRegistry.supports(.displayPower, board: "sdd154"))

        XCTAssertFalse(BoardRegistry.supports(.remoteAnimation, board: "ws175"))
        XCTAssertFalse(BoardRegistry.supports(.remoteAnimation, board: "sdd154"))
    }

    func testBoardHardwareProfilesMatchPhysicalDevices() throws {
        let waveshare = try XCTUnwrap(BoardRegistry.spec(for: "ws175"))
        XCTAssertEqual(waveshare.display, DisplayProfile(width: 466, height: 466, shape: .round))
        XCTAssertTrue(waveshare.inputs.contains(.touch))

        let television = try XCTUnwrap(BoardRegistry.spec(for: "sdd154"))
        XCTAssertEqual(television.display, DisplayProfile(width: 240, height: 240, shape: .square))
        XCTAssertFalse(television.inputs.contains(.touch))
    }
}
