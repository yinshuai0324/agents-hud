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
    /// Absolute path to Codex's local data directory (normally ~/.codex).
    public var codexDir: String
    /// Where Codex stores local rollout transcripts.
    public var codexSessionsDir: String
    /// Absolute path to Gemini CLI's local data directory (normally ~/.gemini).
    public var geminiDir: String
    /// Root containing standard Gemini CLI project chat archives.
    public var geminiChatsDir: String
    /// Local Antigravity CLI records, when that Gemini client is installed.
    public var geminiAntigravityDir: String
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
        codexDir: String? = nil,
        geminiDir: String? = nil,
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
        let resolvedCodexDir = codexDir
            ?? (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".codex")
        self.codexDir = resolvedCodexDir
        self.codexSessionsDir = (resolvedCodexDir as NSString).appendingPathComponent("sessions")
        let resolvedGeminiDir = geminiDir
            ?? (FileManager.default.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent(".gemini")
        self.geminiDir = resolvedGeminiDir
        self.geminiChatsDir = (resolvedGeminiDir as NSString).appendingPathComponent("tmp")
        self.geminiAntigravityDir = (resolvedGeminiDir as NSString).appendingPathComponent("antigravity-cli")
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
        // CODEX_HOME is Codex's own local-data override. CC_SIGNAL_CODEX_DIR is
        // kept as an app-specific escape hatch for testing and custom setups.
        let codexDir = env["CC_SIGNAL_CODEX_DIR"]
            ?? env["CODEX_HOME"]
            ?? (home as NSString).appendingPathComponent(".codex")
        // GEMINI_CLI_HOME is a home root; Gemini CLI creates its .gemini
        // directory below it. CC_SIGNAL_GEMINI_DIR points at .gemini directly.
        let geminiDir = env["CC_SIGNAL_GEMINI_DIR"]
            ?? env["GEMINI_CLI_HOME"].map { ($0 as NSString).appendingPathComponent(".gemini") }
            ?? (home as NSString).appendingPathComponent(".gemini")
        let basis: PercentBasis = env["CC_SIGNAL_PERCENT_BASIS"] == "maxBlock" ? .maxBlock : .budget
        let defaultsPort = defaults.integer(forKey: "serverPort")
        let defaultsToken = defaults.string(forKey: "authToken") ?? ""
        return Config(
            port: envInt("CC_SIGNAL_PORT", defaultsPort > 0 ? defaultsPort : 4317),
            host: env["CC_SIGNAL_HOST"] ?? "0.0.0.0",
            claudeDir: claudeDir,
            codexDir: codexDir,
            geminiDir: geminiDir,
            tokenBudget: envInt("CC_SIGNAL_TOKEN_BUDGET", 2_000_000),
            percentBasis: basis,
            quietAfterMs: envMs("CC_SIGNAL_QUIET_AFTER_MS", 5 * 60_000),
            dropAfterMs: envMs("CC_SIGNAL_DROP_AFTER_MS", 6 * 60 * 60_000),
            workingTimeoutMs: envMs("CC_SIGNAL_WORKING_TIMEOUT_MS", 90_000),
            authToken: env["CC_SIGNAL_TOKEN"] ?? defaultsToken
        )
    }
}
