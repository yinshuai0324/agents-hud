import Foundation

/// Groups timestamped usage into 5-hour billing windows (the ccusage "blocks"
/// model) and returns the currently active window — port of usage5h.ts.
///
/// Algorithm: sort events by time; start a block at the first event floored to
/// the hour (UTC); an event belongs to the current block if it is within 5h of
/// the block start AND within 5h of the previous event (a >5h gap closes the
/// block). The active block is the last one whose end is still in the future.
public enum Usage5hCalculator {
    static let fiveHoursMs: Double = 5 * 60 * 60_000

    /// Floor a timestamp to the top of its hour (UTC) — ccusage block convention.
    static func floorToHour(_ ts: Double) -> Double {
        ts - ts.truncatingRemainder(dividingBy: 60 * 60_000)
    }

    public static func compute(events: [UsageEvent], cfg: Config, now: Double) -> Usage5h {
        let empty = Usage5h(
            percent: 0,
            tokensUsed: 0,
            tokenBudget: cfg.tokenBudget,
            resetInMinutes: 0,
            blockStart: nil,
            blockEnd: nil,
            burnRatePerMin: 0,
            source: "estimate"
        )
        if events.isEmpty { return empty }

        struct Block {
            var start: Double
            var end: Double
            var lastTs: Double
            var tokens: Int
        }

        let sorted = events.sorted { $0.ts < $1.ts }
        var blocks: [Block] = []

        for ev in sorted {
            if var cur = blocks.last,
               ev.ts < cur.start + fiveHoursMs,
               ev.ts - cur.lastTs < fiveHoursMs {
                cur.tokens += ev.tokens
                cur.lastTs = ev.ts
                blocks[blocks.count - 1] = cur
            } else {
                let start = floorToHour(ev.ts)
                blocks.append(Block(start: start, end: start + fiveHoursMs, lastTs: ev.ts, tokens: ev.tokens))
            }
        }

        // Active block: the most recent block whose 5h window has not yet elapsed.
        guard let active = blocks.last, now < active.end else {
            let maxBlock = blocks.reduce(0) { max($0, $1.tokens) }
            var out = empty
            out.tokenBudget = budgetFor(cfg, maxHistoricalBlock: maxBlock)
            return out
        }

        let maxOther = blocks.dropLast().reduce(0) { max($0, $1.tokens) }
        let budget = budgetFor(cfg, maxHistoricalBlock: maxOther)
        let resetInMinutes = max(0, Int(((active.end - now) / 60_000).jsRounded()))
        let elapsedMin = max(1, (now - active.start) / 60_000)
        return Usage5h(
            percent: min(100, Int((Double(active.tokens) / Double(budget) * 100).jsRounded())),
            tokensUsed: active.tokens,
            tokenBudget: budget,
            resetInMinutes: resetInMinutes,
            blockStart: ISO8601Millis.string(fromEpochMs: active.start),
            blockEnd: ISO8601Millis.string(fromEpochMs: active.end),
            burnRatePerMin: Int((Double(active.tokens) / elapsedMin).jsRounded()),
            source: "estimate"
        )
    }

    /// Resolve the denominator for the percent gauge based on config.
    static func budgetFor(_ cfg: Config, maxHistoricalBlock: Int) -> Int {
        if cfg.percentBasis == .maxBlock {
            return max(cfg.tokenBudget, maxHistoricalBlock)
        }
        return cfg.tokenBudget
    }
}

extension Double {
    /// JavaScript Math.round: half-up toward +Infinity (Swift's .rounded() is
    /// half-away-from-zero, which differs for negative .5 values).
    func jsRounded() -> Double {
        (self + 0.5).rounded(.down)
    }
}
