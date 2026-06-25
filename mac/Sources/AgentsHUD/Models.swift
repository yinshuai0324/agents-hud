import Foundation

/// Wire models mirroring the server's Snapshot (see `server/src/state.ts` and
/// `android/.../data/Snapshot.kt`). Decoding is lenient: missing keys fall back
/// to defaults and unknown keys are ignored, so the server can add/remove fields
/// without breaking this build.

struct Snapshot: Decodable {
    var provider = "claude"
    /// Subscription plan display name, e.g. "Max (5x)". Empty if unknown.
    var plan = ""
    /// Model of the most recently active session, e.g. "Opus 4.8 (1M)".
    var model = ""
    var status = Status()
    var usage5h = Usage5h()
    /// Weekly (7-day) limit, present only when Claude provides it.
    var usage7d: UsageWindow?
    /// Today's total spend across all sessions (local day).
    var today = TodayUsage()
    var sessions: [Session] = []
    /// Live output generation speed (tokens/sec) of the fastest streaming session.
    var outputTokensPerSec = 0
    var ts = ""

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        provider = c.v(.provider, "claude")
        plan = c.v(.plan, "")
        model = c.v(.model, "")
        status = c.v(.status, Status())
        usage5h = c.v(.usage5h, Usage5h())
        usage7d = try? c.decodeIfPresent(UsageWindow.self, forKey: .usage7d)
        today = c.v(.today, TodayUsage())
        sessions = c.v(.sessions, [])
        outputTokensPerSec = c.v(.outputTokensPerSec, 0)
        ts = c.v(.ts, "")
    }
    enum K: String, CodingKey {
        case provider, plan, model, status, usage5h, usage7d, today, sessions, outputTokensPerSec, ts
    }
}

struct Status: Decodable {
    var waiting = 0, working = 0, quiet = 0, notify = 0, error = 0
    var dominant = "quiet"
    var total = 0

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        waiting = c.v(.waiting, 0); working = c.v(.working, 0); quiet = c.v(.quiet, 0)
        notify = c.v(.notify, 0); error = c.v(.error, 0)
        dominant = c.v(.dominant, "quiet"); total = c.v(.total, 0)
    }
    enum K: String, CodingKey { case waiting, working, quiet, notify, error, dominant, total }
}

struct Usage5h: Decodable {
    var percent = 0
    var tokensUsed: Int64 = 0
    var tokenBudget: Int64 = 0
    var resetInMinutes = 0
    var blockStart: String?
    var blockEnd: String?
    var burnRatePerMin: Int64 = 0
    /// "live" = real numbers from Claude; "estimate" = local approximation.
    var source = "estimate"

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        percent = c.v(.percent, 0)
        tokensUsed = c.v(.tokensUsed, 0)
        tokenBudget = c.v(.tokenBudget, 0)
        resetInMinutes = c.v(.resetInMinutes, 0)
        blockStart = try? c.decodeIfPresent(String.self, forKey: .blockStart)
        blockEnd = try? c.decodeIfPresent(String.self, forKey: .blockEnd)
        burnRatePerMin = c.v(.burnRatePerMin, 0)
        source = c.v(.source, "estimate")
    }
    enum K: String, CodingKey {
        case percent, tokensUsed, tokenBudget, resetInMinutes, blockStart, blockEnd, burnRatePerMin, source
    }
}

struct UsageWindow: Decodable {
    var percent = 0
    var resetInMinutes = 0

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        percent = c.v(.percent, 0); resetInMinutes = c.v(.resetInMinutes, 0)
    }
    enum K: String, CodingKey { case percent, resetInMinutes }
}

struct TodayUsage: Decodable {
    /// Conversation tokens today: input + output (the "real work").
    var tokens: Int64 = 0
    /// Cache-write tokens today (prompt caching); usually dwarfs [tokens].
    var cacheWriteTokens: Int64 = 0
    /// Equivalent pay-as-you-go cost in USD (billing-accurate; includes cache read).
    var costUSD = 0.0

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        tokens = c.v(.tokens, 0); cacheWriteTokens = c.v(.cacheWriteTokens, 0); costUSD = c.v(.costUSD, 0.0)
    }
    enum K: String, CodingKey { case tokens, cacheWriteTokens, costUSD }
}

struct Session: Decodable, Identifiable {
    var id = ""
    var project = ""
    var cwd = ""
    var state = "quiet"
    var model = ""
    /// Epoch milliseconds of last activity.
    var lastActivity: Int64 = 0
    var tokens: Int64 = 0
    var contextTokens: Int64 = 0
    var contextLeftPercent = 0
    var currentTool = ""

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        id = c.v(.id, ""); project = c.v(.project, ""); cwd = c.v(.cwd, "")
        state = c.v(.state, "quiet"); model = c.v(.model, "")
        lastActivity = c.v(.lastActivity, 0); tokens = c.v(.tokens, 0)
        contextTokens = c.v(.contextTokens, 0); contextLeftPercent = c.v(.contextLeftPercent, 0)
        currentTool = c.v(.currentTool, "")
    }
    enum K: String, CodingKey {
        case id, project, cwd, state, model, lastActivity, tokens, contextTokens, contextLeftPercent, currentTool
    }
}

/// Session state shared by sessions and the dominant indicator.
enum LightState: Hashable {
    case error, notify, waiting, working, quiet
    static func from(_ s: String) -> LightState {
        switch s {
        case "working": return .working
        case "waiting": return .waiting
        case "notify": return .notify
        case "error": return .error
        default: return .quiet
        }
    }
}

private extension KeyedDecodingContainer {
    /// Decode a value, falling back to `def` if the key is missing or mistyped.
    func v<T: Decodable>(_ key: Key, _ def: T) -> T {
        guard let value = try? decode(T.self, forKey: key) else { return def }
        return value
    }
}
