import XCTest
@testable import AgentsHUDCore

final class CodexProviderTests: XCTestCase {
    func testReadsCodexUsageFromLocalRolloutOnly() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-hud-codex-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions/2026/08/16")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date().timeIntervalSince1970 * 1000
        let t1 = ISO8601Millis.string(fromEpochMs: now - 1_000)
        let t2 = ISO8601Millis.string(fromEpochMs: now)
        let reset5 = Int((now + 60 * 60_000) / 1000)
        let reset7 = Int((now + 6 * 24 * 60 * 60_000) / 1000)
        let lines = [
            #"{"timestamp":"\#(t1)","type":"session_meta","payload":{"id":"abc","cwd":"/tmp/example","timestamp":"\#(t1)"}}"#,
            #"{"timestamp":"\#(t1)","type":"turn_context","payload":{"cwd":"/tmp/example","model":"gpt-5.6-sol"}}"#,
            tokenLine(timestamp: t1, input: 100, cached: 20, output: 10, lastInput: 80, reset5: reset5, reset7: reset7),
            tokenLine(timestamp: t2, input: 160, cached: 40, output: 30, lastInput: 60, reset5: reset5, reset7: reset7),
        ]
        let file = sessions.appendingPathComponent("rollout-test.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)

        let cfg = Config(claudeDir: root.appendingPathComponent("claude").path, codexDir: root.path)
        let result = await CodexProvider(cfg: cfg).collect()

        XCTAssertEqual(result.provider, "codex")
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].id, "codex:abc")
        XCTAssertEqual(result.sessions[0].model, "gpt-5.6-sol")
        XCTAssertEqual(result.sessions[0].contextTokens, 60)
        XCTAssertEqual(result.sessions[0].usage.input, 120)
        XCTAssertEqual(result.sessions[0].usage.cacheRead, 40)
        XCTAssertEqual(result.sessions[0].usage.output, 30)
        XCTAssertEqual(result.sessions[0].usage.total, 150)
        XCTAssertEqual(result.usageEvents.map(\.tokens), [60])
        XCTAssertEqual(result.usageWindows.map(\.windowMinutes).sorted(), [300, 10_080])
        XCTAssertEqual(result.plan, "Pro")
        XCTAssertEqual(result.today?.tokens, 190)
        XCTAssertEqual(result.today?.cacheWriteTokens, 0)
    }

    func testAccountQuotaWinsOverNewerModelSpecificQuota() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-hud-codex-scopes-\(UUID().uuidString)")
        let sessions = root.appendingPathComponent("sessions/2026/08/25")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date().timeIntervalSince1970 * 1000
        let t1 = ISO8601Millis.string(fromEpochMs: now - 1_000)
        let t2 = ISO8601Millis.string(fromEpochMs: now)
        let reset5 = Int((now + 60 * 60_000) / 1000)
        let reset7 = Int((now + 6 * 24 * 60 * 60_000) / 1000)
        let lines = [
            #"{"timestamp":"\#(t1)","type":"session_meta","payload":{"id":"scopes","cwd":"/tmp/example"}}"#,
            #"{"timestamp":"\#(t1)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"cache_write_input_tokens":0,"output_tokens":10}},"rate_limits":{"limit_id":"codex","plan_type":"pro","primary":{"used_percent":17,"window_minutes":10080,"resets_at":\#(reset7)},"secondary":null}}}"#,
            #"{"timestamp":"\#(t2)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":160,"cached_input_tokens":40,"cache_write_input_tokens":0,"output_tokens":30}},"rate_limits":{"limit_id":"codex_bengalfox","limit_name":"GPT-5.3-Codex-Spark","plan_type":"pro","primary":{"used_percent":0,"window_minutes":300,"resets_at":\#(reset5)},"secondary":{"used_percent":0,"window_minutes":10080,"resets_at":\#(reset7)}}}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: sessions.appendingPathComponent("rollout-scopes.jsonl"))

        let cfg = Config(claudeDir: root.appendingPathComponent("claude").path, codexDir: root.path)
        let result = await CodexProvider(cfg: cfg).collect()

        XCTAssertEqual(result.usageWindows.count, 1)
        XCTAssertEqual(result.usageWindows.first?.windowMinutes, 10_080)
        XCTAssertEqual(result.usageWindows.first?.percent, 17)
        XCTAssertEqual(result.plan, "Pro")
    }

    func testStateEngineUsesCodexLocalQuotaForActiveCodexSession() async {
        let now = Date().timeIntervalSince1970 * 1000
        var usage = TokenUsage()
        usage.input = 500
        usage.output = 100
        usage.total = 600
        let provider = StubProvider(snapshot: ProviderSnapshot(
            provider: "codex",
            sessions: [SessionData(
                id: "codex:test",
                provider: "codex",
                cwd: "/tmp/project",
                project: "tmp/project",
                model: "gpt-5.6-sol",
                lastActivity: now,
                firstActivity: now - 1_000,
                usage: usage,
                contextTokens: 1_000
            )],
            usageEvents: [UsageEvent(ts: now, tokens: 600)],
            usageWindows: [
                ProviderUsageWindow(percent: 23, windowMinutes: 300, resetsAt: now + 60_000, observedAt: now),
                ProviderUsageWindow(percent: 41, windowMinutes: 10_080, resetsAt: now + 120_000, observedAt: now),
            ],
            plan: "Pro",
            today: TodayUsage(tokens: 600, cacheWriteTokens: 0, costUSD: 0)
        ))
        let cfg = Config(claudeDir: "/tmp/agents-hud-no-claude-\(UUID().uuidString)")
        let engine = StateEngine(cfg: cfg, providers: [provider])
        await engine.start()
        defer { engine.stop() }

        let snapshot = engine.buildSnapshot(now: now)
        XCTAssertEqual(snapshot.provider, "codex")
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.usage5h.percent, 23)
        XCTAssertEqual(snapshot.usage5h.source, "local")
        XCTAssertEqual(snapshot.usage7d?.percent, 41)
        XCTAssertEqual(snapshot.today.tokens, 600)
        XCTAssertEqual(snapshot.sessions.first?.provider, "codex")
    }

    func testProviderSelectionSupportsOneOrBothSources() async {
        let now = Date().timeIntervalSince1970 * 1000
        let claude = StubProvider(snapshot: ProviderSnapshot(
            provider: "claude",
            sessions: [session(id: "claude-1", provider: "claude", model: "claude-sonnet-5", at: now - 1_000)]
        ))
        let codex = StubProvider(snapshot: ProviderSnapshot(
            provider: "codex",
            sessions: [session(id: "codex-1", provider: "codex", model: "gpt-5.6-sol", at: now)]
        ))
        let cfg = Config(claudeDir: "/tmp/agents-hud-selection-\(UUID().uuidString)")
        let engine = StateEngine(
            cfg: cfg,
            providers: [claude, codex],
            enabledProviders: ["claude", "codex"]
        )
        await engine.start()
        defer { engine.stop() }

        var snapshot = engine.buildSnapshot(now: now)
        XCTAssertEqual(snapshot.providers.map(\.provider), ["claude", "codex"])
        XCTAssertEqual(Set(snapshot.sessions.map(\.provider)), ["claude", "codex"])
        XCTAssertEqual(snapshot.provider, "codex")
        let compact = CompactSnapshot.json(from: snapshot, hostName: "Mac")
        XCTAssertTrue(compact.contains(#""pr":"codex""#))
        XCTAssertFalse(compact.contains(#""p5":"#))

        engine.setEnabledProviders(["claude"])
        snapshot = engine.buildSnapshot(now: now)
        XCTAssertEqual(snapshot.providers.map(\.provider), ["claude"])
        XCTAssertEqual(snapshot.sessions.map(\.provider), ["claude"])
        XCTAssertEqual(snapshot.provider, "claude")
    }

    func testExpiredClaudeCacheIsUnknownInsteadOfZero() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agents-hud-expired-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date().timeIntervalSince1970 * 1000
        let cached: [String: Any] = [
            "fiveHour": ["percent": 76, "resetsAt": now - 1_000, "ts": now - 2_000],
            "sevenDay": ["percent": 16, "resetsAt": now - 1_000, "ts": now - 2_000],
        ]
        let data = try JSONSerialization.data(withJSONObject: cached)
        try data.write(to: root.appendingPathComponent(".agentshud-usage.json"))

        let provider = StubProvider(snapshot: ProviderSnapshot(provider: "claude"))
        let engine = StateEngine(cfg: Config(claudeDir: root.path), providers: [provider])
        await engine.start()
        defer { engine.stop() }

        let snapshot = engine.buildSnapshot(now: now)
        XCTAssertEqual(snapshot.usage5h.source, "estimate")
        XCTAssertNil(snapshot.usage7d)
        let compact = CompactSnapshot.json(from: snapshot, hostName: "Mac")
        XCTAssertFalse(compact.contains(#""p5":"#))
        XCTAssertFalse(compact.contains(#""p7":"#))
    }

    func testRefreshWakesQuietCodexSessionWhenTranscriptAdvances() async throws {
        let now = Date().timeIntervalSince1970 * 1000
        let provider = MutableStubProvider(snapshot: ProviderSnapshot(
            provider: "codex",
            sessions: [session(
                id: "codex:wake",
                provider: "codex",
                model: "gpt-5.6-sol",
                at: now - 10 * 60_000
            )]
        ))
        let cfg = Config(claudeDir: "/tmp/agents-hud-wake-\(UUID().uuidString)")
        let engine = StateEngine(cfg: cfg, providers: [provider])
        await engine.start()
        defer { engine.stop() }

        XCTAssertEqual(engine.buildSnapshot(now: now).sessions.first?.state, .quiet)

        provider.setSnapshot(ProviderSnapshot(
            provider: "codex",
            sessions: [session(
                id: "codex:wake",
                provider: "codex",
                model: "gpt-5.6-sol",
                at: now
            )]
        ))
        provider.triggerRefresh()

        for _ in 0..<20 {
            if engine.buildSnapshot(now: now).sessions.first?.state == .working { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertEqual(engine.buildSnapshot(now: now).sessions.first?.state, .working)
    }

    private func session(id: String, provider: String, model: String, at: Double) -> SessionData {
        SessionData(
            id: id,
            provider: provider,
            cwd: "/tmp/\(provider)",
            project: provider,
            model: model,
            lastActivity: at,
            firstActivity: at,
            usage: TokenUsage(),
            contextTokens: 0
        )
    }

    private func tokenLine(
        timestamp: String,
        input: Int,
        cached: Int,
        output: Int,
        lastInput: Int,
        reset5: Int,
        reset7: Int
    ) -> String {
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"cache_write_input_tokens":0,"output_tokens":\#(output),"reasoning_output_tokens":0,"total_tokens":\#(input + output)},"last_token_usage":{"input_tokens":\#(lastInput),"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":\#(lastInput + 1)},"model_context_window":258400},"rate_limits":{"plan_type":"prolite","primary":{"used_percent":23,"window_minutes":300,"resets_at":\#(reset5)},"secondary":{"used_percent":41,"window_minutes":10080,"resets_at":\#(reset7)}}}}"#
    }
}

private final class StubProvider: Provider, @unchecked Sendable {
    let name: String
    let snapshot: ProviderSnapshot

    init(snapshot: ProviderSnapshot) {
        self.snapshot = snapshot
        name = snapshot.provider
    }

    func collect() async -> ProviderSnapshot { snapshot }
    func watch(onChange: @escaping @Sendable (String?) -> Void) -> () -> Void { {} }
}

private final class MutableStubProvider: Provider, @unchecked Sendable {
    let name: String
    private let lock = NSLock()
    private var snapshot: ProviderSnapshot
    private var onChange: (@Sendable (String?) -> Void)?

    init(snapshot: ProviderSnapshot) {
        self.snapshot = snapshot
        name = snapshot.provider
    }

    func setSnapshot(_ value: ProviderSnapshot) {
        lock.lock()
        snapshot = value
        lock.unlock()
    }

    func collect() async -> ProviderSnapshot {
        currentSnapshot()
    }

    private func currentSnapshot() -> ProviderSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func watch(onChange: @escaping @Sendable (String?) -> Void) -> () -> Void {
        lock.lock()
        self.onChange = onChange
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.onChange = nil
            self.lock.unlock()
        }
    }

    func triggerRefresh() {
        lock.lock()
        let callback = onChange
        lock.unlock()
        callback?(nil)
    }
}
