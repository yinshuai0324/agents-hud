import XCTest
@testable import AgentsHUDCore

final class GeminiProviderTests: XCTestCase {
    func testReadsStandardGeminiCLISessionAndTokensFromDisk() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-hud-gemini-\(UUID().uuidString)")
        let chats = root.appendingPathComponent("tmp/project-hash/chats")
        try FileManager.default.createDirectory(at: chats, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date().timeIntervalSince1970 * 1000
        let t1 = ISO8601Millis.string(fromEpochMs: now - 1_000)
        let t2 = ISO8601Millis.string(fromEpochMs: now)
        let json = #"""
        {
          "sessionId": "session-1",
          "projectHash": "0123456789abcdef",
          "startTime": "\#(t1)",
          "lastUpdated": "\#(t2)",
          "messages": [
            {"type":"user","timestamp":"\#(t1)","content":"hello"},
            {"type":"gemini","timestamp":"\#(t1)","model":"gemini-2.5-pro","tokens":{"input":100,"output":20,"cached":30,"thoughts":5,"tool":2,"total":127}},
            {"type":"gemini","timestamp":"\#(t2)","model":"gemini-2.5-pro","tokens":{"input":50,"output":10,"cached":0,"thoughts":0,"tool":0,"total":60}}
          ]
        }
        """#
        try Data(json.utf8).write(to: chats.appendingPathComponent("session-1.json"))

        let cfg = Config(
            claudeDir: root.appendingPathComponent("claude").path,
            geminiDir: root.path
        )
        let result = await GeminiProvider(cfg: cfg).collect()

        XCTAssertEqual(result.provider, "gemini")
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].id, "gemini:session-1")
        XCTAssertEqual(result.sessions[0].project, "Gemini · 01234567")
        XCTAssertEqual(result.sessions[0].model, "gemini-2.5-pro")
        XCTAssertEqual(result.sessions[0].contextTokens, 50)
        XCTAssertEqual(result.sessions[0].usage.input, 120)
        XCTAssertEqual(result.sessions[0].usage.cacheRead, 30)
        XCTAssertEqual(result.sessions[0].usage.output, 37)
        XCTAssertEqual(result.sessions[0].usage.total, 157)
        XCTAssertEqual(result.usageEvents.map(\.tokens), [97, 60])
        XCTAssertEqual(result.today?.tokens, 157)
        XCTAssertTrue(result.usageWindows.isEmpty)
    }

    func testDiscoversRecentAntigravityActivityWithoutInventingUsage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-hud-antigravity-\(UUID().uuidString)")
        let dir = root.appendingPathComponent("antigravity-cli")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date().timeIntervalSince1970 * 1000
        let lines = [
            #"{"conversationId":"abc","workspace":"file:///tmp/demo","timestamp":\#(Int(now - 2_000))}"#,
            #"{"conversationId":"abc","workspace":"file:///tmp/demo","timestamp":\#(Int(now - 1_000))}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: dir.appendingPathComponent("history.jsonl"))

        let cfg = Config(
            claudeDir: root.appendingPathComponent("claude").path,
            geminiDir: root.path
        )
        let result = await GeminiProvider(cfg: cfg).collect()

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].id, "gemini:antigravity:abc")
        XCTAssertEqual(result.sessions[0].cwd, "/tmp/demo")
        XCTAssertEqual(result.sessions[0].project, "tmp/demo")
        XCTAssertEqual(result.sessions[0].usage.total, 0)
        XCTAssertTrue(result.usageEvents.isEmpty)
    }
}
