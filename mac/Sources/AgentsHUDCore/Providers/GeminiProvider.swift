import Foundation

/// Reads Gemini usage from files already stored on this Mac.
///
/// Supported local formats:
/// - Gemini CLI: ~/.gemini/tmp/<project-hash>/chats/*.json (exact token counts)
/// - Antigravity CLI: ~/.gemini/antigravity-cli/history.jsonl (activity only;
///   its protobuf databases are deliberately not guessed or sent elsewhere)
///
/// This provider never reads Gemini credentials and never invokes a Google API.
public final class GeminiProvider: Provider, @unchecked Sendable {
    public let name = "gemini"
    private let cfg: Config
    private var watcher: FSEventsWatcher?

    public init(cfg: Config) {
        self.cfg = cfg
    }

    public func collect() async -> ProviderSnapshot {
        collectFromDisk()
    }

    private func collectFromDisk() -> ProviderSnapshot {
        let now = nowMs()
        let dayStart = TodayUsageScanner.startOfTodayLocal(now: now, timeZone: .current)
        let oldestNeeded = min(dayStart, now - cfg.dropAfterMs)
        var sessions: [SessionData] = []
        var events: [UsageEvent] = []
        var today = TodayUsage.zero

        if let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: cfg.geminiChatsDir),
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "json",
                      url.deletingLastPathComponent().lastPathComponent == "chats",
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true,
                      let mtime = values.contentModificationDate else { continue }
                let modifiedAt = mtime.timeIntervalSince1970 * 1000
                guard modifiedAt >= oldestNeeded else { continue }
                guard let parsed = parseGeminiCLIChat(
                    at: url,
                    fallbackModifiedAt: modifiedAt,
                    includeSession: now - modifiedAt <= cfg.dropAfterMs,
                    dayStart: dayStart
                ) else { continue }
                if let session = parsed.session { sessions.append(session) }
                events.append(contentsOf: parsed.events)
                today.tokens += parsed.today.tokens
            }
        }

        // Antigravity currently stores token metadata in private protobuf blobs.
        // Its JSONL history is still useful for local activity/session discovery,
        // but reporting invented token numbers would be worse than reporting zero.
        sessions.append(contentsOf: parseAntigravityHistory(now: now))

        return ProviderSnapshot(
            provider: name,
            sessions: deduplicated(sessions),
            usageEvents: events,
            today: today
        )
    }

    private struct ParsedChat {
        var session: SessionData?
        var events: [UsageEvent]
        var today: TodayUsage
    }

    private func parseGeminiCLIChat(
        at url: URL,
        fallbackModifiedAt: Double,
        includeSession: Bool,
        dayStart: Double
    ) -> ParsedChat? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let messages = root["messages"] as? [[String: Any]] else { return nil }

        let fileId = url.deletingPathExtension().lastPathComponent
        let rawId = nonEmptyString(root["sessionId"]) ?? fileId
        let projectHash = nonEmptyString(root["projectHash"])
            ?? url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        var first = timestamp(root["startTime"]) ?? Double.infinity
        var last = timestamp(root["lastUpdated"]) ?? 0
        var model = ""
        var usage = TokenUsage()
        var contextTokens = 0
        var events: [UsageEvent] = []
        var today = TodayUsage.zero

        for message in messages {
            guard message["type"] as? String == "gemini" else { continue }
            let ts = timestamp(message["timestamp"])
            if let ts {
                first = min(first, ts)
                last = max(last, ts)
            }
            if let value = nonEmptyString(message["model"]) { model = value }
            guard let rawTokens = message["tokens"] as? [String: Any] else { continue }
            let tokens = GeminiTokenCounts(rawTokens)
            usage.input += tokens.uncachedInput
            usage.output += tokens.generated
            usage.cacheRead += tokens.cached
            usage.total += tokens.work
            contextTokens = tokens.input
            if let ts, tokens.work > 0 {
                events.append(UsageEvent(ts: ts, tokens: tokens.work))
                if ts >= dayStart { today.tokens += tokens.work }
            }
        }

        if last == 0 { last = fallbackModifiedAt }
        if !first.isFinite { first = last }
        let session: SessionData? = includeSession ? SessionData(
            id: "gemini:\(rawId)",
            provider: name,
            cwd: "",
            project: geminiProjectLabel(projectHash),
            model: model,
            lastActivity: last,
            firstActivity: first,
            usage: usage,
            contextTokens: contextTokens
        ) : nil
        return ParsedChat(session: session, events: events, today: today)
    }

    private func parseAntigravityHistory(now: Double) -> [SessionData] {
        let path = (cfg.geminiAntigravityDir as NSString).appendingPathComponent("history.jsonl")
        struct Activity {
            var first: Double
            var last: Double
            var workspace: String
        }
        var byID: [String: Activity] = [:]
        guard JSONLReader.forEachObject(atPath: path, { object in
            guard let id = nonEmptyString(object["conversationId"]),
                  let ts = timestamp(object["timestamp"]),
                  now - ts <= cfg.dropAfterMs else { return }
            let workspace = normalizedWorkspace(nonEmptyString(object["workspace"]) ?? "")
            if var item = byID[id] {
                item.first = min(item.first, ts)
                if ts >= item.last {
                    item.last = ts
                    if !workspace.isEmpty { item.workspace = workspace }
                }
                byID[id] = item
            } else {
                byID[id] = Activity(first: ts, last: ts, workspace: workspace)
            }
        }) else { return [] }

        return byID.map { id, item in
            SessionData(
                id: "gemini:antigravity:\(id)",
                provider: name,
                cwd: item.workspace,
                project: projectLabel(item.workspace),
                model: "",
                lastActivity: item.last,
                firstActivity: item.first,
                usage: TokenUsage(),
                contextTokens: 0
            )
        }
    }

    private func deduplicated(_ sessions: [SessionData]) -> [SessionData] {
        var result: [String: SessionData] = [:]
        for session in sessions {
            if let old = result[session.id], old.lastActivity >= session.lastActivity { continue }
            result[session.id] = session
        }
        return Array(result.values)
    }

    public func watch(onChange: @escaping @Sendable (String?) -> Void) -> () -> Void {
        let w = FSEventsWatcher(path: cfg.geminiDir) { paths in
            if paths.contains(where: {
                $0.hasSuffix(".json") || $0.hasSuffix(".jsonl") || $0.hasSuffix(".db")
            }) {
                onChange(nil)
            }
        }
        watcher = w
        return { [weak self] in
            self?.watcher?.stop()
            self?.watcher = nil
        }
    }
}

private struct GeminiTokenCounts {
    var input: Int
    var output: Int
    var cached: Int
    var thoughts: Int
    var tool: Int
    var total: Int

    init(_ raw: [String: Any]) {
        input = intField(raw, "input")
        output = intField(raw, "output")
        cached = intField(raw, "cached")
        thoughts = intField(raw, "thoughts")
        tool = intField(raw, "tool")
        total = intField(raw, "total")
    }

    var uncachedInput: Int { max(0, input - cached) }
    var generated: Int { output + thoughts + tool }
    var work: Int {
        let componentTotal = uncachedInput + generated
        return total > 0 ? max(0, total - cached) : componentTotal
    }
}

private func timestamp(_ raw: Any?) -> Double? {
    switch raw {
    case let value as String:
        return TimestampParser.epochMs(value) ?? Double(value).map(normalizedEpochMs)
    case let value as NSNumber:
        return normalizedEpochMs(value.doubleValue)
    default:
        return nil
    }
}

private func normalizedEpochMs(_ value: Double) -> Double {
    value > 1_000_000_000_000 ? value : value * 1000
}

private func nonEmptyString(_ raw: Any?) -> String? {
    guard let value = raw as? String, !value.isEmpty else { return nil }
    return value
}

private func normalizedWorkspace(_ raw: String) -> String {
    guard raw.hasPrefix("file:") else { return raw }
    return URL(string: raw)?.path ?? raw
}

private func geminiProjectLabel(_ hash: String) -> String {
    guard !hash.isEmpty else { return "Gemini" }
    return "Gemini · \(hash.prefix(8))"
}
