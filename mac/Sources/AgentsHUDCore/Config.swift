import Foundation

/// Runtime configuration, ported from server/src/config.ts. Env vars keep their
/// CC_SIGNAL_* names so existing hook scripts and user setups keep working;
/// UserDefaults (written by the app's settings UI) take effect when the env is
/// not set.
public struct Config: Sendable {
    /// TCP port for the HTTP + WebSocket server.
    public var port: Int
    /// Bind address. 0.0.0.0 so phones on the LAN can reach it.
    public var host: String
    /// Absolute path to the ~/.claude directory.
    public var claudeDir: String
    /// Where Claude Code stores per-project session transcripts.
    public var projectsDir: String
    /// Token budget used as the denominator for the 5h gauge (estimate mode).
    public var tokenBudget: Int
    /// "budget" or "maxBlock" — how the 5-hour percent is computed.
    public var percentBasis: PercentBasis
    /// A session "waiting" longer than this goes "quiet" (ms).
    public var quietAfterMs: Double
    /// A session with no activity for longer than this is dropped entirely (ms).
    public var dropAfterMs: Double
    /// A "working" session with no events for this long falls back to "waiting" (ms).
    public var workingTimeoutMs: Double
    /// Optional shared secret. Empty string disables auth.
    public var authToken: String

    public enum PercentBasis: String, Sendable {
        case budget
        case maxBlock
    }

    public init(
        port: Int = 4317,
        host: String = "0.0.0.0",
        claudeDir: String,
        tokenBudget: Int = 2_000_000,
        percentBasis: PercentBasis = .budget,
        quietAfterMs: Double = 5 * 60_000,
        dropAfterMs: Double = 6 * 60 * 60_000,
        workingTimeoutMs: Double = 90_000,
        authToken: String = ""
    ) {
        self.port = port
        self.host = host
        self.claudeDir = claudeDir
        self.projectsDir = (claudeDir as NSString).appendingPathComponent("projects")
        self.tokenBudget = tokenBudget
        self.percentBasis = percentBasis
        self.quietAfterMs = quietAfterMs
        self.dropAfterMs = dropAfterMs
        self.workingTimeoutMs = workingTimeoutMs
        self.authToken = authToken
    }

    /// Env override → UserDefaults → default, mirroring loadConfig() in config.ts
    /// (env only) with the app's settings layered underneath.
    public static func load(defaults: UserDefaults = .standard) -> Config {
        let env = ProcessInfo.processInfo.environment
        func envInt(_ name: String, _ fallback: Int) -> Int {
            guard let raw = env[name], !raw.isEmpty, let n = Int(raw) else { return fallback }
            return n
        }
        func envMs(_ name: String, _ fallback: Double) -> Double {
            guard let raw = env[name], !raw.isEmpty, let n = Double(raw), n.isFinite else { return fallback }
            return n
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let claudeDir = env["CC_SIGNAL_CLAUDE_DIR"] ?? (home as NSString).appendingPathComponent(".claude")
        let basis: PercentBasis = env["CC_SIGNAL_PERCENT_BASIS"] == "maxBlock" ? .maxBlock : .budget
        let defaultsPort = defaults.integer(forKey: "serverPort")
        let defaultsToken = defaults.string(forKey: "authToken") ?? ""
        return Config(
            port: envInt("CC_SIGNAL_PORT", defaultsPort > 0 ? defaultsPort : 4317),
            host: env["CC_SIGNAL_HOST"] ?? "0.0.0.0",
            claudeDir: claudeDir,
            tokenBudget: envInt("CC_SIGNAL_TOKEN_BUDGET", 2_000_000),
            percentBasis: basis,
            quietAfterMs: envMs("CC_SIGNAL_QUIET_AFTER_MS", 5 * 60_000),
            dropAfterMs: envMs("CC_SIGNAL_DROP_AFTER_MS", 6 * 60 * 60_000),
            workingTimeoutMs: envMs("CC_SIGNAL_WORKING_TIMEOUT_MS", 90_000),
            authToken: env["CC_SIGNAL_TOKEN"] ?? defaultsToken
        )
    }
}
