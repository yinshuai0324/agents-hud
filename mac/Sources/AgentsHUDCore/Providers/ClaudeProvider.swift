import Foundation
import CoreServices

/// Short label from the last 3 path segments, e.g. /a/b/c/d/e -> "c/d/e".
func projectLabel(_ cwd: String) -> String {
    if cwd.isEmpty { return "unknown" }
    let parts = cwd.split(separator: "/").filter { !$0.isEmpty }
    let label = parts.suffix(3).joined(separator: "/")
    return label.isEmpty ? cwd : label
}

/// Reads Claude Code session transcripts from ~/.claude/projects and exposes
/// them as provider sessions + timestamped usage events — port of claude.ts.
public final class ClaudeProvider: Provider, @unchecked Sendable {
    public let name = "claude"
    private let cfg: Config
    private var watcher: FSEventsWatcher?

    public init(cfg: Config) {
        self.cfg = cfg
    }

    public func collect() async -> ProviderSnapshot {
        var sessions: [SessionData] = []
        var usageEvents: [UsageEvent] = []
        let fm = FileManager.default

        guard let projDirs = try? fm.contentsOfDirectory(atPath: cfg.projectsDir) else {
            return ProviderSnapshot(provider: name)
        }

        let now = Date().timeIntervalSince1970 * 1000
        for projName in projDirs {
            let dirPath = (cfg.projectsDir as NSString).appendingPathComponent(projName)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else { continue }
            guard let files = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }
            for file in files {
                guard file.hasSuffix(".jsonl") else { continue }
                let full = (dirPath as NSString).appendingPathComponent(file)
                guard let attrs = try? fm.attributesOfItem(atPath: full),
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                // Skip sessions inactive longer than the drop window; they are
                // neither shown nor counted toward the live 5h block.
                if now - mtime.timeIntervalSince1970 * 1000 > cfg.dropAfterMs { continue }
                let sessionId = String(file.dropLast(".jsonl".count))
                if let session = parseFile(full, sessionId: sessionId, usageEvents: &usageEvents) {
                    sessions.append(session)
                }
            }
        }
        return ProviderSnapshot(provider: name, sessions: sessions, usageEvents: usageEvents)
    }

    private func parseFile(
        _ filePath: String,
        sessionId: String,
        usageEvents: inout [UsageEvent]
    ) -> SessionData? {
        var usage = TokenUsage()
        var cwd = ""
        var model = ""
        var first = Double.infinity
        var last: Double = 0
        var sawAny = false
        // Current context occupancy = the most recent request's input + cache.
        var contextTokens = 0
        // One assistant turn spans several JSONL lines (one per content block),
        // each repeating the same `usage`. Count tokens once per message.id;
        // without this a session's totals (and the 5h estimate) inflate ~2-3x.
        var countedMsgIds = Set<String>()

        let opened = JSONLReader.forEachObject(atPath: filePath) { d in
            if let c = d["cwd"] as? String, !c.isEmpty { cwd = c }
            let ts: Double? = (d["timestamp"] as? String).flatMap(TimestampParser.epochMs)
            if let ts {
                sawAny = true
                if ts < first { first = ts }
                if ts > last { last = ts }
            }
            guard d["type"] as? String == "assistant",
                  let message = d["message"] as? [String: Any] else { return }
            if let m = message["model"] as? String { model = m }
            guard let u = message["usage"] as? [String: Any] else { return }
            let id = message["id"] as? String ?? ""
            let isDup = id.isEmpty ? false : countedMsgIds.contains(id)
            if !id.isEmpty { countedMsgIds.insert(id) }
            if !isDup {
                let newWork = addUsage(&usage, u)
                if let ts, newWork > 0 {
                    usageEvents.append(UsageEvent(ts: ts, tokens: newWork))
                }
            }
            contextTokens = intField(u, "input_tokens")
                + intField(u, "cache_read_input_tokens")
                + intField(u, "cache_creation_input_tokens")
        }
        guard opened else { return nil }

        if !sawAny {
            // No timestamped content; fall back to file mtime so it still shows up.
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: filePath),
                  let mtime = attrs[.modificationDate] as? Date else { return nil }
            last = mtime.timeIntervalSince1970 * 1000
            let birth = (attrs[.creationDate] as? Date)?.timeIntervalSince1970
            first = birth.map { $0 * 1000 } ?? last
        }

        return SessionData(
            id: sessionId,
            provider: name,
            cwd: cwd,
            project: projectLabel(cwd),
            model: model,
            lastActivity: last,
            firstActivity: first.isFinite ? first : last,
            usage: usage,
            contextTokens: contextTokens
        )
    }

    /// Watches the projects directory recursively for transcript writes using
    /// FSEvents (macOS-native recursive watching, like fs.watch on darwin).
    public func watch(onChange: @escaping @Sendable (String?) -> Void) -> () -> Void {
        let w = FSEventsWatcher(path: cfg.projectsDir) { paths in
            for p in paths {
                guard p.hasSuffix(".jsonl") else { continue }
                let base = ((p as NSString).lastPathComponent as NSString).deletingPathExtension
                onChange(base)
            }
        }
        watcher = w
        return { [weak self] in
            self?.watcher?.stop()
            self?.watcher = nil
        }
    }
}

/// "New work" tokens for one message: input + output + cacheCreate (cacheRead
/// excluded — it is not "new" work).
func messageWork(_ u: [String: Any]) -> Int {
    intField(u, "input_tokens") + intField(u, "output_tokens") + intField(u, "cache_creation_input_tokens")
}

func addUsage(_ into: inout TokenUsage, _ u: [String: Any]) -> Int {
    into.input += intField(u, "input_tokens")
    into.output += intField(u, "output_tokens")
    into.cacheCreate += intField(u, "cache_creation_input_tokens")
    into.cacheRead += intField(u, "cache_read_input_tokens")
    let newWork = messageWork(u)
    into.total += newWork
    return newWork
}

/// Number(x) || 0 for a JSON field (handles Int/Double/NSNumber and strings).
func intField(_ obj: [String: Any], _ key: String) -> Int {
    numField(obj[key])
}

func numField(_ v: Any?) -> Int {
    switch v {
    case let n as Int: return n
    case let n as Double: return n.isFinite ? Int(n) : 0
    case let n as NSNumber: return n.intValue
    case let s as String: return Int(Double(s)?.rounded(.towardZero) ?? 0)
    default: return 0
    }
}

/// Thin FSEvents wrapper delivering changed file paths on a background queue.
final class FSEventsWatcher {
    private var streamRef: FSEventStreamRef?
    private let callback: ([String]) -> Void
    private let queue = DispatchQueue(label: "com.ooimi.agents.hud.fsevents")

    init?(path: String, callback: @escaping ([String]) -> Void) {
        self.callback = callback
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let cb: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
            guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            watcher.callback(Array(paths.prefix(numEvents)))
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            cb,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.3, // latency: small batching window, refresh timers cover the rest
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        ) else { return nil }
        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
    }

    deinit { stop() }
}
