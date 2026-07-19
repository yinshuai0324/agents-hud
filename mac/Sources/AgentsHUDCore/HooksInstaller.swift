import Foundation

/// Installs (or removes) the Agents-HUD hook bridge into ~/.claude/settings.json
/// — port of setup-hooks.ts. The destination script paths are unchanged
/// (~/.claude/agents-hud/*.sh), so settings written by the old Node installer
/// stay valid: installing from the app simply overwrites the scripts in place.
public enum HooksInstaller {
    static let marker = "cc-signal-hook.sh"
    static let statuslineMarker = "cc-signal-statusline.sh"
    static let events = [
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Stop",
        "StopFailure",
        "Notification",
        "SessionStart",
        "SessionEnd",
    ]

    public struct Result: Sendable {
        public var settingsPath: String
        public var hookScriptPath: String
        public var statuslineInstalled: Bool
        /// Non-nil when an existing custom statusLine was left untouched.
        public var statuslineWarning: String?
    }

    public enum InstallError: Error, LocalizedError {
        case missingScript(String)
        case unwritableSettings(String)

        public var errorDescription: String? {
            switch self {
            case let .missingScript(p): return "Hook script not found at \(p)"
            case let .unwritableSettings(p): return "Could not write \(p)"
            }
        }
    }

    /// Install hooks + statusLine. `scriptsSourceDir` is the app-bundle
    /// directory containing cc-signal-hook.sh / cc-signal-statusline.sh.
    public static func install(cfg: Config, scriptsSourceDir: URL) throws -> Result {
        let fm = FileManager.default
        let settingsPath = (cfg.claudeDir as NSString).appendingPathComponent("settings.json")
        let destDir = (cfg.claudeDir as NSString).appendingPathComponent("agents-hud")
        let scriptPath = (destDir as NSString).appendingPathComponent(marker)
        let statusPath = (destDir as NSString).appendingPathComponent(statuslineMarker)

        let srcScript = scriptsSourceDir.appendingPathComponent(marker)
        let srcStatus = scriptsSourceDir.appendingPathComponent(statuslineMarker)
        guard fm.fileExists(atPath: srcScript.path) else {
            throw InstallError.missingScript(srcScript.path)
        }

        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        for (src, dst) in [(srcScript, scriptPath), (srcStatus, statusPath)] {
            if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: dst) }
            try fm.copyItem(atPath: src.path, toPath: dst)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst)
        }

        var settings = readSettings(settingsPath)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Always strip our existing entries first (idempotent install).
        stripOurEntries(&hooks)

        // Back up before writing changes.
        if fm.fileExists(atPath: settingsPath) {
            let backup = settingsPath + ".cc-signal.bak"
            try? fm.removeItem(atPath: backup)
            try? fm.copyItem(atPath: settingsPath, toPath: backup)
        }

        let entry: [String: Any] = [
            "matcher": "*",
            "hooks": [[
                "type": "command",
                "command": scriptPath,
                "args": [String(cfg.port)],
                "async": true,
                "timeout": 5,
            ] as [String: Any]],
        ]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(entry)
            hooks[event] = groups
        }
        settings["hooks"] = hooks

        // Install the statusLine bridge (delivers Claude's REAL plan usage).
        // Don't clobber a pre-existing custom statusLine.
        var statuslineInstalled = false
        var warning: String?
        let existingStatus = settings["statusLine"] as? [String: Any]
        let existingCmd = existingStatus?["command"] as? String ?? ""
        if existingStatus != nil && !existingCmd.contains(statuslineMarker) {
            warning = "已检测到自定义 statusLine，未覆盖。要获取真实用量，请把 statusLine.command 设为：\(statusPath) \(cfg.port)"
        } else {
            settings["statusLine"] = [
                "type": "command",
                "command": "\(statusPath) \(cfg.port)",
                "padding": 0,
            ] as [String: Any]
            statuslineInstalled = true
        }

        try writeSettings(settings, to: settingsPath)
        return Result(
            settingsPath: settingsPath,
            hookScriptPath: scriptPath,
            statuslineInstalled: statuslineInstalled,
            statuslineWarning: warning
        )
    }

    /// Remove our hooks + statusLine (only our entries).
    public static func uninstall(cfg: Config) throws {
        let settingsPath = (cfg.claudeDir as NSString).appendingPathComponent("settings.json")
        var settings = readSettings(settingsPath)
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        stripOurEntries(&hooks)
        if hooks.isEmpty {
            settings["hooks"] = nil
        } else {
            settings["hooks"] = hooks
        }
        if let sl = settings["statusLine"] as? [String: Any],
           let cmd = sl["command"] as? String,
           cmd.contains(statuslineMarker) {
            settings["statusLine"] = nil
        }
        try writeSettings(settings, to: settingsPath)
    }

    /// True when our hook entries are present in ~/.claude/settings.json.
    public static func isInstalled(cfg: Config) -> Bool {
        let settingsPath = (cfg.claudeDir as NSString).appendingPathComponent("settings.json")
        let settings = readSettings(settingsPath)
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for (_, groups) in hooks {
            guard let groups = groups as? [[String: Any]] else { continue }
            if groups.contains(where: isOurEntry) { return true }
        }
        return false
    }

    private static func stripOurEntries(_ hooks: inout [String: Any]) {
        for event in events {
            guard let groups = hooks[event] as? [[String: Any]] else { continue }
            let cleaned = groups.filter { !isOurEntry($0) }
            if cleaned.isEmpty {
                hooks[event] = nil
            } else {
                hooks[event] = cleaned
            }
        }
    }

    private static func isOurEntry(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains {
            ($0["command"] as? String)?.contains(marker) == true
        }
    }

    private static func readSettings(_ path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func writeSettings(_ settings: [String: Any], to path: String) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        var text = String(decoding: data, as: UTF8.self)
        // JSONSerialization escapes "/" — undo for readability, like the Node output.
        text = text.replacingOccurrences(of: "\\/", with: "/")
        guard let out = (text + "\n").data(using: .utf8) else {
            throw InstallError.unwritableSettings(path)
        }
        try out.write(to: URL(fileURLWithPath: path))
    }
}
