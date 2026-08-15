import Foundation

/// Lifecycle state of a single agent session (providers/types.ts).
public enum SessionState: String, Codable, Sendable {
    case working, waiting, notify, error, quiet
}

/// Token counters aggregated from a session's transcript.
public struct TokenUsage: Sendable {
    public var input = 0
    public var output = 0
    public var cacheCreate = 0
    public var cacheRead = 0
    /// input + output + cacheCreate (cacheRead excluded — it is not "new" work).
    public var total = 0
    public init() {}
}

/// A single coding-agent session as read from disk (providers/types.ts).
public struct SessionData: Sendable {
    public var id: String
    public var provider: String
    public var cwd: String
    public var project: String
    public var model: String
    /// Epoch ms of the last activity observed (file mtime / last message).
    public var lastActivity: Double
    /// Epoch ms of the first message (used for the 5h block boundary).
    public var firstActivity: Double
    public var usage: TokenUsage
    /// Current context-window occupancy (last request's input + cache), 0 if unknown.
    public var contextTokens: Int
}

/// A single timestamped chunk of token spend, for the 5-hour window math.
public struct UsageEvent: Sendable {
    public var ts: Double
    public var tokens: Int
    public init(ts: Double, tokens: Int) {
        self.ts = ts
        self.tokens = tokens
    }
}

/// Everything a provider reads from disk in one pass.
public struct ProviderSnapshot: Sendable {
    public var provider: String
    public var sessions: [SessionData]
    public var usageEvents: [UsageEvent]
    /// Exact quota windows observed in this provider's local transcript.
    public var usageWindows: [ProviderUsageWindow]
    /// Provider-local subscription label, when recorded on disk.
    public var plan: String
    /// Provider-local daily usage. nil means this provider does not calculate it.
    public var today: TodayUsage?

    public init(
        provider: String = "",
        sessions: [SessionData] = [],
        usageEvents: [UsageEvent] = [],
        usageWindows: [ProviderUsageWindow] = [],
        plan: String = "",
        today: TodayUsage? = nil
    ) {
        self.provider = provider
        self.sessions = sessions
        self.usageEvents = usageEvents
        self.usageWindows = usageWindows
        self.plan = plan
        self.today = today
    }
}

/// A rate-limit window already present in a provider's local transcript.
/// No network request is made by Agents HUD to obtain it.
public struct ProviderUsageWindow: Sendable {
    public var percent: Int
    public var windowMinutes: Int
    public var resetsAt: Double?
    public var observedAt: Double

    public init(percent: Int, windowMinutes: Int, resetsAt: Double?, observedAt: Double) {
        self.percent = percent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.observedAt = observedAt
    }
}

/// 5-hour usage gauge (usage5h.ts). blockStart/blockEnd serialize as explicit
/// null when absent, matching Node's JSON.stringify.
public struct Usage5h: Codable, Sendable {
    public var percent: Int
    public var tokensUsed: Int
    public var tokenBudget: Int
    public var resetInMinutes: Int
    public var blockStart: String?
    public var blockEnd: String?
    public var burnRatePerMin: Int
    public var source: String // "live" | "estimate"

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(percent, forKey: .percent)
        try c.encode(tokensUsed, forKey: .tokensUsed)
        try c.encode(tokenBudget, forKey: .tokenBudget)
        try c.encode(resetInMinutes, forKey: .resetInMinutes)
        try c.encode(blockStart, forKey: .blockStart) // nil -> null
        try c.encode(blockEnd, forKey: .blockEnd)
        try c.encode(burnRatePerMin, forKey: .burnRatePerMin)
        try c.encode(source, forKey: .source)
    }
}

/// A secondary usage window (weekly), shown alongside the 5h gauge.
public struct UsageWindow: Codable, Sendable {
    public var percent: Int
    public var resetInMinutes: Int
}

/// Today's spend, summed across every session (today.ts).
public struct TodayUsage: Codable, Sendable {
    public var tokens: Int
    public var cacheWriteTokens: Int
    public var costUSD: Double
    public static let zero = TodayUsage(tokens: 0, cacheWriteTokens: 0, costUSD: 0)
}

public struct WireSession: Codable, Sendable {
    public var id: String
    public var provider: String
    public var project: String
    public var cwd: String
    public var state: SessionState
    public var model: String
    public var lastActivity: Double
    public var tokens: Int
    public var contextTokens: Int
    public var contextLeftPercent: Int
    public var currentTool: String

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(provider, forKey: .provider)
        try c.encode(project, forKey: .project)
        try c.encode(cwd, forKey: .cwd)
        try c.encode(state, forKey: .state)
        try c.encode(model, forKey: .model)
        // lastActivity is epoch ms; Node emits it as an integer-valued number.
        try c.encode(EpochMs(lastActivity), forKey: .lastActivity)
        try c.encode(tokens, forKey: .tokens)
        try c.encode(contextTokens, forKey: .contextTokens)
        try c.encode(contextLeftPercent, forKey: .contextLeftPercent)
        try c.encode(currentTool, forKey: .currentTool)
    }
}

/// Status block of the snapshot.
public struct StatusCounts: Codable, Sendable {
    public var waiting: Int
    public var working: Int
    public var quiet: Int
    public var notify: Int
    public var error: Int
    public var dominant: SessionState
    public var total: Int
}

/// Usage data for one enabled provider. The legacy top-level fields in
/// `Snapshot` still mirror the currently active provider for old clients and
/// device firmware; multi-provider clients render this list directly.
public struct ProviderUsageSummary: Codable, Sendable {
    public var provider: String
    public var plan: String
    public var model: String
    public var usage5h: Usage5h
    public var usage7d: UsageWindow?
    public var today: TodayUsage

    public init(
        provider: String,
        plan: String,
        model: String,
        usage5h: Usage5h,
        usage7d: UsageWindow?,
        today: TodayUsage
    ) {
        self.provider = provider
        self.plan = plan
        self.model = model
        self.usage5h = usage5h
        self.usage7d = usage7d
        self.today = today
    }
}

/// Wire format pushed to clients. Keep in sync with the Android Snapshot model.
public struct Snapshot: Codable, Sendable {
    public var provider: String
    public var plan: String
    public var model: String
    public var status: StatusCounts
    public var usage5h: Usage5h
    /// Weekly (7-day) limit from Claude, when available; explicit null otherwise.
    public var usage7d: UsageWindow?
    public var today: TodayUsage
    /// One entry per enabled source, in stable UI order.
    public var providers: [ProviderUsageSummary]
    public var sessions: [WireSession]
    public var outputTokensPerSec: Int
    public var ts: String

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(provider, forKey: .provider)
        try c.encode(plan, forKey: .plan)
        try c.encode(model, forKey: .model)
        try c.encode(status, forKey: .status)
        try c.encode(usage5h, forKey: .usage5h)
        try c.encode(usage7d, forKey: .usage7d) // nil -> null, like JSON.stringify
        try c.encode(today, forKey: .today)
        try c.encode(providers, forKey: .providers)
        try c.encode(sessions, forKey: .sessions)
        try c.encode(outputTokensPerSec, forKey: .outputTokensPerSec)
        try c.encode(ts, forKey: .ts)
    }

    /// Serialized wire JSON (single line, no key sorting — clients parse keys).
    public func jsonData() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data("{}".utf8)
    }
}

/// Epoch-milliseconds wrapper: encodes without a fractional part when whole,
/// matching how JavaScript stringifies Date.now()-derived numbers.
struct EpochMs: Codable {
    let value: Double
    init(_ value: Double) { self.value = value }
    init(from decoder: Decoder) throws {
        value = try decoder.singleValueContainer().decode(Double.self)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        if value.rounded() == value, value.magnitude < 9e15 {
            try c.encode(Int64(value))
        } else {
            try c.encode(value)
        }
    }
}

/// Shared ISO8601-with-milliseconds formatter matching Date.toISOString().
public enum ISO8601Millis {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f
    }()

    public static func string(fromEpochMs ms: Double) -> String {
        formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
    }
}
