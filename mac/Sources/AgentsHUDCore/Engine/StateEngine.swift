import Foundation

/// Friendly model name from a raw id, e.g. "claude-opus-4-8[1m]" -> "Opus 4.8 (1M)".
func prettyModel(_ id: String) -> String {
    if id.isEmpty { return "" }
    let oneM = id.range(of: "\\[1m\\]$", options: [.regularExpression, .caseInsensitive]) != nil
    var s = id
        .replacingRegex("(?i)\\[1m\\]$", with: "")
        .replacingRegex("-\\d{8}$", with: "")
        .replacingRegex("^claude-", with: "")
    if let re = try? NSRegularExpression(pattern: "^(opus|sonnet|haiku|fable)-(\\d+)-(\\d+)", options: [.caseInsensitive]),
       let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
       let famR = Range(m.range(at: 1), in: s),
       let majR = Range(m.range(at: 2), in: s),
       let minR = Range(m.range(at: 3), in: s) {
        let fam = String(s[famR])
        s = "\(fam.prefix(1).uppercased())\(fam.dropFirst()) \(s[majR]).\(s[minR])"
    }
    return oneM ? "\(s) (1M)" : s
}

/// The state machine behind the wire snapshot — port of state.ts. All mutable
/// state is confined behind a lock; Node's single thread is emulated by taking
/// the lock in every entry point (hooks, statusline, file events, timers).
public final class StateEngine: @unchecked Sendable {
    // MARK: - Internal state (guarded by `lock`)

    private struct Runtime {
        var state: SessionState
        /// Last time any activity signal arrived (hook or file write).
        var lastSignalAt: Double
        /// When the session entered "waiting" (for the quiet timeout).
        var waitingSince: Double
        /// Once a hook is seen for a session, hooks drive its state authoritatively.
        var hookMode: Bool
        /// Tool currently/most-recently invoked this turn (from PreToolUse), "" if none.
        var currentTool: String
    }

    private struct LiveWindow: Codable {
        var percent: Int
        var resetsAt: Double? // epoch ms
        var ts: Double // when received
    }

    /// Per-session info harvested from that session's statusLine payload.
    private struct LiveSession {
        var name: String
        var model: String // pretty display_name from statusLine, "" if unknown
        var ctxLeft: Int // remaining_percentage, or -1 if unknown
        var ctxTokens: Int // current context occupancy, or 0
        var ts: Double
        var outputTokens: Int
        var outAt: Double
        var outTokPerSec: Int
    }

    /// Output-speed sampling window, mirroring claude-hud's speed-tracker.
    private static let speedMaxDeltaMs: Double = 4000
    private static let speedMinDeltaMs: Double = 500
    /// Real statusLine usage is trusted for this long before falling back to estimate.
    private static let liveTTLMs: Double = 20 * 60_000
    private static let fiveHourMs: Double = 5 * 60 * 60_000
    private static let sevenDayMs: Double = 7 * 24 * 60 * 60_000

    private let lock = NSRecursiveLock()
    private var runtimes: [String: Runtime] = [:]
    private var sessions: [String: SessionData] = [:]
    private var usageEvents: [UsageEvent] = []
    private var listeners: [UUID: @Sendable (Snapshot) -> Void] = [:]
    private var lastJson = Data()
    private var liveFiveHour: LiveWindow?
    private var liveSevenDay: LiveWindow?
    private var liveSessions: [String: LiveSession] = [:]
    /// Cached full-disk tally of today's spend; refreshed on a slow timer.
    private var todayUsage: TodayUsage = .zero

    private let cfg: Config
    private let providers: [Provider]
    private let planResolver: PlanResolver
    private var timers: [DispatchSourceTimer] = []
    private var watchDisposers: [() -> Void] = []
    private let timerQueue = DispatchQueue(label: "com.ooimi.agents.hud.engine")

    public init(cfg: Config, providers: [Provider], planResolver: PlanResolver = PlanResolver()) {
        self.cfg = cfg
        self.providers = providers
        self.planResolver = planResolver
    }

    // MARK: - Usage cache (survives restarts)

    private var usageCachePath: String {
        (cfg.claudeDir as NSString).appendingPathComponent(".agentshud-usage.json")
    }

    /// Restore the cached 5h/7d windows so a restart doesn't blank them out.
    /// File format is shared with the Node server for a seamless migration.
    private func loadUsageCache() {
        guard let data = FileManager.default.contents(atPath: usageCachePath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        liveFiveHour = Self.decodeWindow(obj["fiveHour"])
        liveSevenDay = Self.decodeWindow(obj["sevenDay"])
    }

    private static func decodeWindow(_ v: Any?) -> LiveWindow? {
        guard let d = v as? [String: Any] else { return nil }
        let resetsAt: Double?
        if let n = d["resetsAt"] as? NSNumber { resetsAt = n.doubleValue } else { resetsAt = nil }
        return LiveWindow(
            percent: numField(d["percent"]),
            resetsAt: resetsAt,
            ts: (d["ts"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    private func saveUsageCache() {
        var obj: [String: Any] = [:]
        obj["fiveHour"] = Self.encodeWindow(liveFiveHour)
        obj["sevenDay"] = Self.encodeWindow(liveSevenDay)
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: URL(fileURLWithPath: usageCachePath))
        }
    }

    private static func encodeWindow(_ w: LiveWindow?) -> Any {
        guard let w else { return NSNull() }
        var d: [String: Any] = ["percent": w.percent, "ts": w.ts]
        d["resetsAt"] = w.resetsAt ?? NSNull()
        return d
    }

    // MARK: - Lifecycle

    public func onSnapshot(_ fn: @escaping @Sendable (Snapshot) -> Void) -> () -> Void {
        let id = UUID()
        lock.lock()
        listeners[id] = fn
        lock.unlock()
        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.listeners[id] = nil
            self.lock.unlock()
        }
    }

    public func start() async {
        restoreUsageCache()
        await refresh()
        for p in providers {
            watchDisposers.append(p.watch { [weak self] id in self?.onFileChange(id) })
        }
        // Periodic refresh: picks up token totals, new/removed sessions, and
        // runs the idle-timeout transitions.
        addTimer(intervalMs: 3000) { [weak self] in
            guard let self else { return }
            Task { await self.refresh() }
        }
        addTimer(intervalMs: 1000) { [weak self] in self?.tickAndEmit() }
        // Today's spend is a full-disk scan: compute now, then every 30s.
        refreshTodayUsage()
        addTimer(intervalMs: 30_000) { [weak self] in self?.refreshTodayUsage() }
    }

    public func stop() {
        for t in timers { t.cancel() }
        timers = []
        for d in watchDisposers { d() }
        watchDisposers = []
    }

    private func addTimer(intervalMs: Int, _ body: @escaping @Sendable () -> Void) {
        let t = DispatchSource.makeTimerSource(queue: timerQueue)
        t.schedule(deadline: .now() + .milliseconds(intervalMs), repeating: .milliseconds(intervalMs))
        t.setEventHandler(handler: body)
        t.resume()
        timers.append(t)
    }

    /// Recompute today's spend from disk and push if it moved the snapshot.
    private func refreshTodayUsage() {
        let usage = TodayUsageScanner.compute(cfg: cfg)
        lock.lock()
        todayUsage = usage
        lock.unlock()
        tickAndEmit()
    }

    /// Re-read all providers from disk and reconcile runtime state.
    private func refresh() async {
        var collected: [ProviderSnapshot] = []
        for p in providers {
            collected.append(await p.collect())
        }
        applyRefresh(collected)
        tickAndEmit()
    }

    private func restoreUsageCache() {
        lock.lock()
        loadUsageCache()
        lock.unlock()
    }

    private func applyRefresh(_ collected: [ProviderSnapshot]) {
        let now = nowMs()
        lock.lock()
        var seen = Set<String>()
        var allEvents: [UsageEvent] = []
        for snap in collected {
            allEvents.append(contentsOf: snap.usageEvents)
            for s in snap.sessions {
                seen.insert(s.id)
                sessions[s.id] = s
                if runtimes[s.id] == nil {
                    runtimes[s.id] = initialRuntime(s, now: now)
                }
            }
        }
        usageEvents = allEvents
        // Drop sessions the providers no longer report (aged out beyond dropAfterMs).
        for id in sessions.keys where !seen.contains(id) {
            sessions[id] = nil
            runtimes[id] = nil
            liveSessions[id] = nil
        }
        lock.unlock()
    }

    private func initialRuntime(_ s: SessionData, now: Double) -> Runtime {
        let age = now - s.lastActivity
        let state: SessionState
        if age < cfg.workingTimeoutMs { state = .working }
        else if age < cfg.quietAfterMs { state = .waiting }
        else { state = .quiet }
        return Runtime(
            state: state,
            lastSignalAt: s.lastActivity,
            waitingSince: state == .waiting ? s.lastActivity : 0,
            hookMode: false,
            currentTool: ""
        )
    }

    // MARK: - Inputs

    /// Map a Claude Code hook event name to a coarse activity signal.
    static func hookToSignal(_ event: String) -> String? {
        switch event {
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolBatch", "SessionStart":
            return "working"
        case "Stop": return "waiting"
        case "Notification": return "notify"
        case "StopFailure": return "error"
        case "SessionEnd": return "end"
        default: return nil
        }
    }

    /// Called by the HTTP /hooks endpoint.
    public func handleHook(event: String, sessionId: String, cwd: String?, toolLabel: String?) {
        guard !sessionId.isEmpty, let signal = Self.hookToSignal(event) else { return }
        let now = nowMs()
        lock.lock()

        if signal == "end" {
            // Treat as quiet immediately; refresh() will drop it once aged out.
            if var rt = runtimes[sessionId] {
                rt.state = .quiet
                rt.currentTool = ""
                rt.hookMode = true
                runtimes[sessionId] = rt
            }
            lock.unlock()
            tickAndEmit()
            return
        }

        var rt = runtimes[sessionId] ?? {
            // Create a placeholder session so it shows up before disk catches up.
            if sessions[sessionId] == nil {
                sessions[sessionId] = placeholderSession(id: sessionId, cwd: cwd ?? "", now: now)
            }
            return Runtime(state: .quiet, lastSignalAt: now, waitingSince: 0, hookMode: true, currentTool: "")
        }()
        rt.hookMode = true
        rt.lastSignalAt = now
        if signal == "working" {
            rt.state = .working
            rt.waitingSince = 0
        } else {
            // waiting | notify | error — the signal value is also the state name.
            rt.state = SessionState(rawValue: signal) ?? .waiting
            rt.waitingSince = now
        }
        // Track the live tool: set on PreToolUse, keep it through PostToolUse,
        // and clear it on anything that ends the tool run.
        if event == "PreToolUse" {
            if let toolLabel, !toolLabel.isEmpty { rt.currentTool = toolLabel }
        } else if event != "PostToolUse" && event != "PostToolBatch" {
            rt.currentTool = ""
        }
        runtimes[sessionId] = rt
        if var s = sessions[sessionId] {
            // Any hook signal is fresh activity — bump lastActivity so a new
            // state moves this session to the top, which drives the light.
            s.lastActivity = now
            if let cwd, !cwd.isEmpty, s.cwd.isEmpty {
                s.cwd = cwd
                let label = cwd.split(separator: "/").filter { !$0.isEmpty }.suffix(3).joined(separator: "/")
                s.project = label.isEmpty ? s.project : label
            }
            sessions[sessionId] = s
        }
        lock.unlock()
        tickAndEmit()
    }

    private func placeholderSession(id: String, cwd: String, now: Double) -> SessionData {
        let project = cwd.isEmpty
            ? "…"
            : cwd.split(separator: "/").filter { !$0.isEmpty }.suffix(3).joined(separator: "/")
        return SessionData(
            id: id,
            provider: providers.first?.name ?? "claude",
            cwd: cwd,
            project: project.isEmpty ? "…" : project,
            model: "",
            lastActivity: now,
            firstActivity: now,
            usage: TokenUsage(),
            contextTokens: 0
        )
    }

    /// Called by the HTTP /statusline endpoint with the JSON Claude Code pipes
    /// to a statusLine command. We harvest the real `rate_limits` which
    /// originate from Claude's own /api/oauth/usage — no credentials touched.
    public func handleStatusline(_ data: [String: Any]) {
        let now = nowMs()
        lock.lock()

        // Per-session info: title + Claude's own context-window numbers.
        let sid = stringField(data["session_id"])
        if !sid.isEmpty {
            let cw = data["context_window"] as? [String: Any]
            var ctxTokens = numField(cw?["total_input_tokens"])
            if ctxTokens == 0, let u = cw?["current_usage"] as? [String: Any] {
                ctxTokens = intField(u, "input_tokens")
                    + intField(u, "cache_creation_input_tokens")
                    + intField(u, "cache_read_input_tokens")
            }
            let ctxLeft: Int
            if let rp = cw?["remaining_percentage"] as? NSNumber, rp.doubleValue.isFinite {
                ctxLeft = clampPct(rp.doubleValue)
            } else {
                ctxLeft = -1
            }
            let model = data["model"] as? [String: Any]
            let modelName = (model?["display_name"] as? String)
                ?? prettyModel(stringField(model?["id"]))

            // Output speed (tok/s): the rate the current turn's output_tokens
            // grows between statusLine updates.
            let outNow = numField((cw?["current_usage"] as? [String: Any])?["output_tokens"])
            let prev = liveSessions[sid]
            var outputTokens = outNow
            var outAt = now
            var outTokPerSec = 0
            if let prev {
                let dMs = now - prev.outAt
                if outNow < prev.outputTokens {
                    // Counter went backwards → a new turn started; reset baseline.
                    outTokPerSec = 0
                } else if dMs < Self.speedMinDeltaMs {
                    // Too soon to measure reliably; keep the old sample.
                    outputTokens = prev.outputTokens
                    outAt = prev.outAt
                    outTokPerSec = prev.outTokPerSec
                } else if dMs <= Self.speedMaxDeltaMs && outNow > prev.outputTokens {
                    outTokPerSec = Int((Double(outNow - prev.outputTokens) / (dMs / 1000)).jsRounded())
                }
                // dMs > max with no growth → stale; reset (speed 0).
            }

            liveSessions[sid] = LiveSession(
                name: data["session_name"] as? String ?? "",
                model: modelName,
                ctxLeft: ctxLeft,
                ctxTokens: ctxTokens,
                ts: now,
                outputTokens: outputTokens,
                outAt: outAt,
                outTokPerSec: outTokPerSec
            )
        }

        guard let rl = data["rate_limits"] as? [String: Any] else {
            lock.unlock()
            tickAndEmit()
            return
        }
        if let fh = rl["five_hour"] as? [String: Any] {
            liveFiveHour = LiveWindow(
                percent: clampPctAny(fh["used_percentage"]),
                resetsAt: parseReset(fh["resets_at"]),
                ts: now
            )
        }
        if let sd = rl["seven_day"] as? [String: Any] {
            liveSevenDay = LiveWindow(
                percent: clampPctAny(sd["used_percentage"]),
                resetsAt: parseReset(sd["resets_at"]),
                ts: now
            )
        }
        if rl["five_hour"] != nil || rl["seven_day"] != nil { saveUsageCache() }
        lock.unlock()
        tickAndEmit()
    }

    /// File write detected by a provider watcher.
    private func onFileChange(_ sessionId: String?) {
        guard let sessionId else {
            Task { await refresh() }
            return
        }
        let now = nowMs()
        lock.lock()
        guard var rt = runtimes[sessionId] else {
            lock.unlock()
            // Unknown session: let refresh() discover it.
            Task { await refresh() }
            return
        }
        if var s = sessions[sessionId] {
            s.lastActivity = now
            sessions[sessionId] = s
        }
        // In hook mode, hooks own the state; a file write only refreshes activity.
        if rt.hookMode {
            rt.lastSignalAt = now
            runtimes[sessionId] = rt
            lock.unlock()
            tickAndEmit()
            return
        }
        rt.state = .working
        rt.lastSignalAt = now
        rt.waitingSince = 0
        runtimes[sessionId] = rt
        lock.unlock()
        tickAndEmit()
    }

    // MARK: - Output

    /// Apply idle-timeout transitions, then emit if the snapshot changed.
    private func tickAndEmit() {
        let now = nowMs()
        lock.lock()
        for (id, var rt) in runtimes {
            var changed = false
            if rt.state == .working, now - rt.lastSignalAt > cfg.workingTimeoutMs {
                rt.state = .waiting
                rt.waitingSince = now
                rt.currentTool = ""
                changed = true
            }
            if rt.state == .waiting, now - rt.waitingSince > cfg.quietAfterMs {
                rt.state = .quiet
                changed = true
            }
            if changed { runtimes[id] = rt }
        }
        let snap = buildSnapshotLocked(now: now)
        // Compare without `ts` so heartbeat-only changes don't spam clients.
        var noTs = snap
        noTs.ts = ""
        let json = noTs.jsonData()
        if json == lastJson {
            lock.unlock()
            return
        }
        lastJson = json
        let fns = Array(listeners.values)
        lock.unlock()
        for fn in fns { fn(snap) }
    }

    public func buildSnapshot(now: Double = Date().timeIntervalSince1970 * 1000) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return buildSnapshotLocked(now: now)
    }

    private func buildSnapshotLocked(now: Double) -> Snapshot {
        var waiting = 0, working = 0, quiet = 0, notify = 0, error = 0
        var wire: [WireSession] = []
        for (id, s) in sessions {
            let rt = runtimes[id]
            let state = rt?.state ?? .quiet
            switch state {
            case .waiting: waiting += 1
            case .working: working += 1
            case .notify: notify += 1
            case .error: error += 1
            case .quiet: quiet += 1
            }
            // Prefer Claude's own statusLine numbers/title when fresh.
            let live = liveSessions[id]
            let liveFresh = live != nil && now - live!.ts < Self.liveTTLMs
            let ctx = liveFresh && live!.ctxTokens > 0 ? live!.ctxTokens : (s.contextTokens != 0 ? s.contextTokens : 0)
            let contextLeftPercent: Int
            if liveFresh, live!.ctxLeft >= 0 {
                contextLeftPercent = live!.ctxLeft
            } else if ctx > 0 {
                let window = ctx > 200_000 ? 1_000_000.0 : 200_000.0
                contextLeftPercent = max(0, Int(((1 - Double(ctx) / window) * 100).jsRounded()))
            } else {
                contextLeftPercent = 0
            }
            let project = liveFresh && !(live!.name.isEmpty) ? live!.name : s.project
            wire.append(WireSession(
                id: id,
                project: project,
                cwd: s.cwd,
                state: state,
                model: s.model,
                lastActivity: s.lastActivity,
                tokens: s.usage.total,
                contextTokens: ctx,
                contextLeftPercent: contextLeftPercent,
                currentTool: state == .working ? (rt?.currentTool ?? "") : ""
            ))
        }
        wire.sort { $0.lastActivity > $1.lastActivity }

        // Current model = the most recently active session's model.
        var currentModel = ""
        if let top = wire.first {
            let live = liveSessions[top.id]
            if let live, !live.model.isEmpty, now - live.ts < Self.liveTTLMs {
                currentModel = live.model
            } else {
                currentModel = prettyModel(top.model)
            }
        }

        // Live output speed: the fastest session still actively streaming.
        var outputTokensPerSec = 0
        for live in liveSessions.values {
            if now - live.ts <= Self.speedMaxDeltaMs, live.outTokPerSec > outputTokensPerSec {
                outputTokensPerSec = live.outTokPerSec
            }
        }

        // Follow the most recently active session (wire is sorted newest-first).
        let dominant = wire.first?.state ?? .quiet

        // Prefer Claude's real 5h numbers (from statusLine) over the local estimate.
        var usage5h = Usage5hCalculator.compute(events: usageEvents, cfg: cfg, now: now)
        if let liveFive = effectiveLiveWindow(liveFiveHour, windowMs: Self.fiveHourMs, now: now) {
            usage5h.percent = liveFive.percent
            usage5h.resetInMinutes = minutesUntil(liveFive.resetsAt, now: now) ?? usage5h.resetInMinutes
            usage5h.source = "live"
        }

        var usage7d: UsageWindow?
        if let liveSeven = effectiveLiveWindow(liveSevenDay, windowMs: Self.sevenDayMs, now: now) {
            usage7d = UsageWindow(
                percent: liveSeven.percent,
                resetInMinutes: minutesUntil(liveSeven.resetsAt, now: now) ?? 0
            )
        }

        return Snapshot(
            provider: providers.first?.name ?? "claude",
            plan: planResolver.resolve(now: now),
            model: currentModel,
            status: StatusCounts(
                waiting: waiting, working: working, quiet: quiet, notify: notify,
                error: error, dominant: dominant,
                total: waiting + working + quiet + notify + error
            ),
            usage5h: usage5h,
            usage7d: usage7d,
            today: todayUsage,
            sessions: wire,
            outputTokensPerSec: outputTokensPerSec,
            ts: ISO8601Millis.string(fromEpochMs: now)
        )
    }

    /// Resolve a live rate-limit window to what should be shown *right now*,
    /// rolling it forward across any reset boundaries that have already elapsed
    /// (see effectiveLiveWindow in state.ts for the full rationale).
    private func effectiveLiveWindow(
        _ w: LiveWindow?, windowMs: Double, now: Double
    ) -> (percent: Int, resetsAt: Double?)? {
        guard let w else { return nil }
        guard let resetsAt = w.resetsAt else {
            return now - w.ts < Self.liveTTLMs ? (w.percent, nil) : nil
        }
        if now < resetsAt { return (w.percent, resetsAt) }
        // The window reset while no fresh statusLine arrived — roll forward to
        // the current window and show it freshly empty until real numbers land.
        let periods = ((now - resetsAt) / windowMs).rounded(.down) + 1
        return (0, resetsAt + periods * windowMs)
    }
}

func nowMs() -> Double {
    Date().timeIntervalSince1970 * 1000
}

func stringField(_ v: Any?) -> String {
    switch v {
    case let s as String: return s
    case let n as NSNumber: return n.stringValue
    case nil, is NSNull: return ""
    default: return String(describing: v!)
    }
}

/// Parse a rate-limit reset value: ISO string, epoch seconds, or epoch ms.
func parseReset(_ v: Any?) -> Double? {
    switch v {
    case nil, is NSNull:
        return nil
    case let n as NSNumber:
        let d = n.doubleValue
        return d > 1e12 ? d : d * 1000 // s -> ms heuristic
    case let s as String:
        if let n = Double(s), n.isFinite {
            return n > 1e12 ? n : n * 1000
        }
        return TimestampParser.epochMs(s)
    default:
        return nil
    }
}

func minutesUntil(_ resetsAt: Double?, now: Double) -> Int? {
    guard let resetsAt else { return nil }
    return max(0, Int(((resetsAt - now) / 60_000).jsRounded()))
}

func clampPct(_ n: Double) -> Int {
    if !n.isFinite { return 0 }
    return max(0, min(100, Int(n.jsRounded())))
}

func clampPctAny(_ v: Any?) -> Int {
    switch v {
    case let n as NSNumber: return clampPct(n.doubleValue)
    case let s as String: return clampPct(Double(s) ?? .nan)
    default: return 0
    }
}
