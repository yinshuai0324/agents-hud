import Foundation

/// Reads Codex's local rollout transcripts from ~/.codex/sessions.
///
/// This provider is intentionally offline-only: it never reads auth.json and
/// never calls an OpenAI endpoint. Token totals and quota windows come from the
/// `token_count` events that Codex already persisted in its JSONL transcript.
public final class CodexProvider: Provider, @unchecked Sendable {
    public let name = "codex"
    private let cfg: Config
    private var watcher: FSEventsWatcher?

    public init(cfg: Config) {
        self.cfg = cfg
    }

    public func collect() async -> ProviderSnapshot {
        collectFromDisk()
    }

    /// Keep Foundation's synchronous directory enumerator out of the async
    /// function body (required by Swift 6 strict concurrency).
    private func collectFromDisk() -> ProviderSnapshot {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: cfg.codexSessionsDir),
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return ProviderSnapshot(provider: name, today: .zero)
        }

        let now = nowMs()
        let dayStart = TodayUsageScanner.startOfTodayLocal(now: now, timeZone: .current)
        let oldestNeeded = min(dayStart, now - cfg.dropAfterMs)
        var sessions: [SessionData] = []
        var usageEvents: [UsageEvent] = []
        var today = TodayUsage.zero
        var generalLimits: RateLimitObservation?
        var scopedLimits: RateLimitObservation?

        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate else { continue }
            let modifiedAt = mtime.timeIntervalSince1970 * 1000
            guard modifiedAt >= oldestNeeded else { continue }

            let includeSession = now - modifiedAt <= cfg.dropAfterMs
            let includeToday = modifiedAt >= dayStart
            let parsed = parseFile(
                url.path,
                includeSession: includeSession,
                includeTodayFrom: includeToday ? dayStart : nil
            )
            if let session = parsed.session { sessions.append(session) }
            usageEvents.append(contentsOf: parsed.usageEvents)
            today.tokens += parsed.today.tokens
            today.cacheWriteTokens += parsed.today.cacheWriteTokens
            if let candidate = parsed.generalLimits {
                generalLimits = Self.merging(generalLimits, with: candidate)
            }
            if let candidate = parsed.scopedLimits {
                scopedLimits = Self.merging(scopedLimits, with: candidate)
            }
        }

        // Codex can interleave the account-wide quota (limit_id "codex") with
        // model-specific buckets such as "codex_bengalfox" in different
        // rollout files. A model bucket often reports 0/0 and must not replace
        // the account-wide weekly quota merely because it was written a moment
        // later. Prefer the general quota; only use a scoped bucket on older
        // transcripts that contain no general record at all.
        let limits = generalLimits ?? scopedLimits

        return ProviderSnapshot(
            provider: name,
            sessions: sessions,
            usageEvents: usageEvents,
            usageWindows: limits?.windows ?? [],
            plan: limits?.plan ?? "",
            today: today
        )
    }

    private struct ParsedFile {
        var session: SessionData?
        var usageEvents: [UsageEvent]
        var today: TodayUsage
        var generalLimits: RateLimitObservation?
        var scopedLimits: RateLimitObservation?
    }

    private struct RateLimitObservation {
        var ts: Double
        var windows: [ProviderUsageWindow]
        var plan: String
    }

    private func parseFile(
        _ filePath: String,
        includeSession: Bool,
        includeTodayFrom dayStart: Double?
    ) -> ParsedFile {
        var sessionId = ((filePath as NSString).lastPathComponent as NSString).deletingPathExtension
        var cwd = ""
        var model = ""
        var first = Double.infinity
        var last: Double = 0
        var contextTokens = 0
        var latestUsage = TokenUsage()
        var previousCumulative: CodexTokenCounts?
        var usageEvents: [UsageEvent] = []
        var today = TodayUsage.zero
        var generalLimits: RateLimitObservation?
        var scopedLimits: RateLimitObservation?

        let opened = JSONLReader.forEachObject(atPath: filePath) { object in
            let ts = (object["timestamp"] as? String).flatMap(TimestampParser.epochMs)
            if let ts {
                first = min(first, ts)
                last = max(last, ts)
            }

            switch object["type"] as? String {
            case "session_meta":
                guard let payload = object["payload"] as? [String: Any] else { return }
                let id = stringField(payload["id"])
                if !id.isEmpty { sessionId = id }
                if let value = payload["cwd"] as? String, !value.isEmpty { cwd = value }

            case "turn_context":
                guard let payload = object["payload"] as? [String: Any] else { return }
                if let value = payload["cwd"] as? String, !value.isEmpty { cwd = value }
                if let value = payload["model"] as? String, !value.isEmpty { model = value }

            case "event_msg":
                guard let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let total = info["total_token_usage"] as? [String: Any],
                      let timestamp = ts else { return }

                let cumulative = CodexTokenCounts(total)
                latestUsage = cumulative.sessionUsage
                if let lastUsage = info["last_token_usage"] as? [String: Any] {
                    contextTokens = intField(lastUsage, "input_tokens")
                }

                if let previous = previousCumulative {
                    let delta = cumulative.positiveDelta(from: previous)
                    if delta.workTokens > 0 {
                        usageEvents.append(UsageEvent(ts: timestamp, tokens: delta.workTokens))
                    }
                    if let dayStart, timestamp >= dayStart {
                        today.tokens += delta.input + delta.output
                        today.cacheWriteTokens += delta.cacheWrite
                    }
                } else {
                    // A rollout created today has no pre-midnight baseline, so
                    // its first cumulative counter belongs to today.
                    if let dayStart, first >= dayStart {
                        today.tokens += cumulative.input + cumulative.output
                        today.cacheWriteTokens += cumulative.cacheWrite
                    }
                }
                previousCumulative = cumulative

                if let rawLimits = payload["rate_limits"] as? [String: Any] {
                    let windows = Self.parseWindows(rawLimits, observedAt: timestamp)
                    if !windows.isEmpty {
                        let observation = RateLimitObservation(
                            ts: timestamp,
                            windows: windows,
                            plan: Self.prettyPlan(stringField(rawLimits["plan_type"]))
                        )
                        let limitID = stringField(rawLimits["limit_id"]).lowercased()
                        if limitID.isEmpty || limitID == "codex" {
                            generalLimits = Self.merging(generalLimits, with: observation)
                        } else {
                            scopedLimits = Self.merging(scopedLimits, with: observation)
                        }
                    }
                }

            default:
                break
            }
        }

        guard opened else {
            return ParsedFile(
                session: nil,
                usageEvents: [],
                today: .zero,
                generalLimits: nil,
                scopedLimits: nil
            )
        }
        let session: SessionData?
        if includeSession, last > 0 {
            session = SessionData(
                id: "codex:\(sessionId)",
                provider: name,
                cwd: cwd,
                project: projectLabel(cwd),
                model: model,
                lastActivity: last,
                firstActivity: first.isFinite ? first : last,
                usage: latestUsage,
                contextTokens: contextTokens
            )
        } else {
            session = nil
        }
        return ParsedFile(
            session: session,
            usageEvents: usageEvents,
            today: today,
            generalLimits: generalLimits,
            scopedLimits: scopedLimits
        )
    }

    /// Merge independently by window duration. Some newer Codex events carry
    /// only one window, so replacing the whole observation would erase the
    /// other still-valid window.
    private static func merging(
        _ current: RateLimitObservation?,
        with candidate: RateLimitObservation
    ) -> RateLimitObservation {
        guard var merged = current else { return candidate }
        for window in candidate.windows {
            if let index = merged.windows.firstIndex(where: {
                $0.windowMinutes == window.windowMinutes
            }) {
                if window.observedAt >= merged.windows[index].observedAt {
                    merged.windows[index] = window
                }
            } else {
                merged.windows.append(window)
            }
        }
        if candidate.ts >= merged.ts {
            merged.ts = candidate.ts
            if !candidate.plan.isEmpty { merged.plan = candidate.plan }
        }
        return merged
    }

    private static func parseWindows(
        _ raw: [String: Any],
        observedAt: Double
    ) -> [ProviderUsageWindow] {
        ["primary", "secondary"].compactMap { key in
            guard let item = raw[key] as? [String: Any] else { return nil }
            let minutes = intField(item, "window_minutes")
            guard minutes > 0 else { return nil }
            let reset = parseReset(item["resets_at"])
            return ProviderUsageWindow(
                percent: max(0, min(100, Int((item["used_percent"] as? NSNumber)?.doubleValue.rounded() ?? 0))),
                windowMinutes: minutes,
                resetsAt: reset,
                observedAt: observedAt
            )
        }
    }

    static func prettyPlan(_ raw: String) -> String {
        switch raw.lowercased() {
        case "": return ""
        case "free": return "Free"
        case "plus": return "Plus"
        case "pro", "prolite", "pro_lite": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        default:
            return raw.replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    public func watch(onChange: @escaping @Sendable (String?) -> Void) -> () -> Void {
        let w = FSEventsWatcher(path: cfg.codexSessionsDir) { paths in
            for path in paths where path.hasSuffix(".jsonl") {
                let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                let id = file.split(separator: "-").suffix(5).joined(separator: "-")
                onChange(id.isEmpty ? nil : "codex:\(id)")
            }
        }
        watcher = w
        return { [weak self] in
            self?.watcher?.stop()
            self?.watcher = nil
        }
    }
}

private struct CodexTokenCounts {
    var input: Int
    var cachedInput: Int
    var cacheWrite: Int
    var output: Int

    init(_ raw: [String: Any]) {
        input = intField(raw, "input_tokens")
        cachedInput = intField(raw, "cached_input_tokens")
        cacheWrite = intField(raw, "cache_write_input_tokens")
        output = intField(raw, "output_tokens")
    }

    var workTokens: Int { max(0, input - cachedInput) + cacheWrite + output }

    var sessionUsage: TokenUsage {
        var value = TokenUsage()
        value.input = max(0, input - cachedInput)
        value.output = output
        value.cacheCreate = cacheWrite
        value.cacheRead = cachedInput
        value.total = workTokens
        return value
    }

    func positiveDelta(from previous: CodexTokenCounts) -> CodexTokenCounts {
        CodexTokenCounts(
            input: max(0, input - previous.input),
            cachedInput: max(0, cachedInput - previous.cachedInput),
            cacheWrite: max(0, cacheWrite - previous.cacheWrite),
            output: max(0, output - previous.output)
        )
    }

    private init(input: Int, cachedInput: Int, cacheWrite: Int, output: Int) {
        self.input = input
        self.cachedInput = cachedInput
        self.cacheWrite = cacheWrite
        self.output = output
    }
}
