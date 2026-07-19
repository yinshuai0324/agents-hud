import Foundation

/// Resolves the user's subscription plan display name (e.g. "Max (5x)") from
/// ~/.claude.json's oauthAccount.organizationRateLimitTier — port of plan.ts.
/// Read-only; never touches credentials. Cached briefly (60s).
public final class PlanResolver: @unchecked Sendable {
    private let tierNames: [String: String] = [
        "default_claude_max_20x": "Max (20x)",
        "default_claude_max_5x": "Max (5x)",
        "claude_pro": "Pro",
        "default_claude_pro": "Pro",
        "default_claude_zero": "Free",
    ]

    private let ttlMs: Double = 60_000
    private var cachedValue = ""
    private var cachedAt: Double = 0
    private let lock = NSLock()
    private let claudeJsonPath: String

    public init(homeDir: String = FileManager.default.homeDirectoryForCurrentUser.path) {
        claudeJsonPath = (homeDir as NSString).appendingPathComponent(".claude.json")
    }

    public func resolve(now: Double = Date().timeIntervalSince1970 * 1000) -> String {
        lock.lock()
        defer { lock.unlock() }
        if now - cachedAt < ttlMs { return cachedValue }
        var value = ""
        if let data = FileManager.default.contents(atPath: claudeJsonPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let acct = obj["oauthAccount"] as? [String: Any] {
            let tier = (acct["organizationRateLimitTier"] as? String)
                ?? (acct["userRateLimitTier"] as? String)
            value = prettyTier(tier)
        }
        cachedValue = value
        cachedAt = now
        return value
    }

    private func prettyTier(_ tier: String?) -> String {
        guard let tier, !tier.isEmpty else { return "" }
        if let known = tierNames[tier] { return known }
        // Fallback: turn "default_claude_max_5x" -> "Max (5x)"
        if let re = try? NSRegularExpression(pattern: "max_(\\d+)x", options: [.caseInsensitive]),
           let m = re.firstMatch(in: tier, range: NSRange(tier.startIndex..., in: tier)),
           let r = Range(m.range(at: 1), in: tier) {
            return "Max (\(tier[r])x)"
        }
        if tier.range(of: "pro", options: [.caseInsensitive]) != nil { return "Pro" }
        if tier.range(of: "zero", options: [.caseInsensitive]) != nil
            || tier.range(of: "free", options: [.caseInsensitive]) != nil { return "Free" }
        return tier
    }
}
