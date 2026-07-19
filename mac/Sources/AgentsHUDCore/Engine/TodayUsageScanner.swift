import Foundation

/// Accurately tally today's token spend — port of today.ts.
///
/// Unlike the live session collector, this scans *all* transcripts (not just
/// ones active within dropAfterMs) so a session that finished hours ago this
/// morning still counts. Files untouched since before midnight are skipped —
/// they can't contain a message timestamped today. Within each file, messages
/// are filtered by their own `timestamp` (not the file mtime), deduped by
/// `message.id`, and priced per model.
public enum TodayUsageScanner {
    /// Local midnight (start of today) as epoch ms. The time zone is
    /// injectable so tests are deterministic across machines.
    static func startOfTodayLocal(now: Double, timeZone: TimeZone) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = cal.startOfDay(for: Date(timeIntervalSince1970: now / 1000))
        return day.timeIntervalSince1970 * 1000
    }

    public static func compute(
        cfg: Config,
        now: Double = Date().timeIntervalSince1970 * 1000,
        timeZone: TimeZone = .current
    ) -> TodayUsage {
        let dayStart = startOfTodayLocal(now: now, timeZone: timeZone)
        var byModel: [String: Pricing.TokenCounts] = [:]
        var counted = Set<String>()
        let fm = FileManager.default

        guard let projDirs = try? fm.contentsOfDirectory(atPath: cfg.projectsDir) else {
            return .zero
        }

        for projName in projDirs {
            let dirPath = (cfg.projectsDir as NSString).appendingPathComponent(projName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for file in files {
                guard file.hasSuffix(".jsonl") else { continue }
                let full = (dirPath as NSString).appendingPathComponent(file)
                // A file not written since before midnight has no messages from today.
                guard let attrs = try? fm.attributesOfItem(atPath: full),
                      let mtime = attrs[.modificationDate] as? Date,
                      mtime.timeIntervalSince1970 * 1000 >= dayStart else { continue }
                scanFile(full, dayStart: dayStart, byModel: &byModel, counted: &counted)
            }
        }

        var tokens = 0
        var cacheWriteTokens = 0
        var costUSD = 0.0
        for (model, c) in byModel {
            tokens += c.input + c.output
            cacheWriteTokens += c.cacheWrite5m + c.cacheWrite1h
            costUSD += Pricing.costFor(model, c)
        }
        return TodayUsage(tokens: tokens, cacheWriteTokens: cacheWriteTokens, costUSD: costUSD)
    }

    private static func scanFile(
        _ filePath: String,
        dayStart: Double,
        byModel: inout [String: Pricing.TokenCounts],
        counted: inout Set<String>
    ) {
        JSONLReader.forEachObject(atPath: filePath) { d in
            guard d["type"] as? String == "assistant",
                  let message = d["message"] as? [String: Any] else { return }
            guard let tsStr = d["timestamp"] as? String,
                  let ts = TimestampParser.epochMs(tsStr),
                  ts >= dayStart else { return }
            guard let u = message["usage"] as? [String: Any] else { return }
            let id = message["id"] as? String ?? ""
            if !id.isEmpty {
                if counted.contains(id) { return }
                counted.insert(id)
            }
            let model = message["model"] as? String ?? "unknown"
            var c = byModel[model] ?? Pricing.TokenCounts()
            c.input += intField(u, "input_tokens")
            c.output += intField(u, "output_tokens")
            c.cacheRead += intField(u, "cache_read_input_tokens")
            // Split cache writes by TTL when the breakdown is present; otherwise
            // the whole amount defaults to the 5-minute tier (Claude Code's default).
            let cc = u["cache_creation"] as? [String: Any]
            let w5 = cc?["ephemeral_5m_input_tokens"]
            let w1 = cc?["ephemeral_1h_input_tokens"]
            if isFiniteNumber(w5) || isFiniteNumber(w1) {
                c.cacheWrite5m += isFiniteNumber(w5) ? numField(w5) : 0
                c.cacheWrite1h += isFiniteNumber(w1) ? numField(w1) : 0
            } else {
                c.cacheWrite5m += intField(u, "cache_creation_input_tokens")
            }
            byModel[model] = c
        }
    }

    /// Number.isFinite(Number(v)) for a JSON value — true only for real numbers
    /// (or numeric strings), mirroring the TTL-breakdown presence check.
    private static func isFiniteNumber(_ v: Any?) -> Bool {
        switch v {
        case is Int: return true
        case let d as Double: return d.isFinite
        case let n as NSNumber: return n.doubleValue.isFinite
        case let s as String: return Double(s)?.isFinite ?? false
        default: return false
        }
    }
}
