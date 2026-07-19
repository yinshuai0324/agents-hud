import Foundation

/// Per-model API pricing, USD per 1,000,000 tokens — port of pricing.ts.
/// Cache tokens are priced off the model's input rate (read 0.1×, write 5m
/// 1.25×, write 1h 2.0×). Unknown models fall back to Opus-tier rates so the
/// number errs high rather than silently undercounting.
public enum Pricing {
    public struct ModelRate: Sendable {
        public let input: Double // USD per 1M input tokens
        public let output: Double // USD per 1M output tokens
    }

    /// Token counts for one model, split so cache tiers can be priced correctly.
    public struct TokenCounts: Sendable {
        public var input = 0
        public var output = 0
        public var cacheRead = 0
        public var cacheWrite5m = 0
        public var cacheWrite1h = 0
        public init() {}
    }

    private static let cacheReadMult = 0.1
    private static let cacheWrite5mMult = 1.25
    private static let cacheWrite1hMult = 2.0

    private static let rates: [(test: NSRegularExpression, rate: ModelRate)] = {
        func re(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p)
        }
        return [
            (re("^(fable|mythos)-5"), ModelRate(input: 10, output: 50)),
            (re("^opus-4-(5|6|7|8)\\b"), ModelRate(input: 5, output: 25)),
            (re("^opus-(4-(0|1)|3)\\b"), ModelRate(input: 15, output: 75)),
            (re("^sonnet-"), ModelRate(input: 3, output: 15)),
            (re("^haiku-4"), ModelRate(input: 1, output: 5)),
            (re("^haiku-3"), ModelRate(input: 0.8, output: 4)),
        ]
    }()

    private static let fallback = ModelRate(input: 5, output: 25)

    /// Normalize a raw model id: drop `claude-` prefix, `[1m]` marker, date suffix.
    static func normalize(_ id: String) -> String {
        var s = id.lowercased()
        s = s.replacingRegex("\\[1m\\]$", with: "")
        s = s.replacingRegex("-\\d{8}$", with: "")
        s = s.replacingRegex("^claude-", with: "")
        return s
    }

    /// Resolve per-model rates. Returns nil for synthetic/internal messages (free).
    public static func rateFor(_ modelId: String) -> ModelRate? {
        let id = normalize(modelId)
        if id.isEmpty || id.hasPrefix("<") { return nil } // "<synthetic>" etc.
        for (test, rate) in rates {
            if test.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil {
                return rate
            }
        }
        return fallback
    }

    /// Cost in USD for a model's token counts. Synthetic models cost 0.
    public static func costFor(_ modelId: String, _ t: TokenCounts) -> Double {
        guard let rate = rateFor(modelId) else { return 0 }
        let inPerTok = rate.input / 1_000_000
        let outPerTok = rate.output / 1_000_000
        return Double(t.input) * inPerTok
            + Double(t.output) * outPerTok
            + Double(t.cacheRead) * inPerTok * cacheReadMult
            + Double(t.cacheWrite5m) * inPerTok * cacheWrite5mMult
            + Double(t.cacheWrite1h) * inPerTok * cacheWrite1hMult
    }
}

extension String {
    /// Regex replace helper (first/anchored patterns as used above).
    func replacingRegex(_ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return self }
        return re.stringByReplacingMatches(
            in: self, range: NSRange(startIndex..., in: self), withTemplate: template
        )
    }
}
