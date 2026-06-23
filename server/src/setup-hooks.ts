/**
 * Installs (or removes) the Agents-HUD hook bridge into ~/.claude/settings.json.
 *
 *   npm run setup-hooks        # install
 *   npm run uninstall-hooks    # remove (restores nothing else; only our entries)
 *
 * Idempotent: existing Agents-HUD entries are stripped before (re)adding, and the
 * original settings.json is backed up to settings.json.cc-signal.bak on install.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadConfig } from "./config.js";

const MARKER = "cc-signal-hook.sh";
const STATUSLINE_MARKER = "cc-signal-statusline.sh";
const EVENTS = [
  "UserPromptSubmit",
  "PreToolUse",
  "PostToolUse",
  "Stop",
  "StopFailure",
  "Notification",
  "SessionStart",
  "SessionEnd",
];

function hookScriptPath(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(here, "..", "hooks", "cc-signal-hook.sh");
}

function statuslineScriptPath(): string {
  const here = path.dirname(fileURLToPath(import.meta.url));
  return path.resolve(here, "..", "hooks", "cc-signal-statusline.sh");
}

function isOurEntry(group: any): boolean {
  const hooks = group?.hooks;
  if (!Array.isArray(hooks)) return false;
  return hooks.some((h: any) => typeof h?.command === "string" && h.command.includes(MARKER));
}

/** Remove all Agents-HUD groups from an event's matcher-group array. */
function stripOurs(groups: any[]): any[] {
  return groups.filter((g) => !isOurEntry(g));
}

function readSettings(file: string): any {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return {};
  }
}

function main() {
  const uninstall = process.argv.includes("--uninstall");
  const cfg = loadConfig();
  const settingsPath = path.join(cfg.claudeDir, "settings.json");

  // Copy the bridge scripts to a stable location under ~/.claude so the paths
  // written into settings.json survive Homebrew upgrades (the install dir is
  // versioned and changes every release).
  const destDir = path.join(cfg.claudeDir, "agents-hud");
  const scriptPath = path.join(destDir, "cc-signal-hook.sh");
  const statusPath = path.join(destDir, "cc-signal-statusline.sh");

  if (!uninstall) {
    const srcScript = hookScriptPath();
    const srcStatus = statuslineScriptPath();
    if (!fs.existsSync(srcScript)) {
      console.error(`Hook script not found at ${srcScript}`);
      process.exit(1);
    }
    fs.mkdirSync(destDir, { recursive: true });
    fs.copyFileSync(srcScript, scriptPath);
    fs.copyFileSync(srcStatus, statusPath);
    for (const p of [scriptPath, statusPath]) {
      try {
        fs.chmodSync(p, 0o755);
      } catch {
        /* best effort */
      }
    }
  }

  const settings = readSettings(settingsPath);
  if (!settings.hooks || typeof settings.hooks !== "object") settings.hooks = {};

  // Always strip our existing entries first (idempotent install + uninstall).
  for (const event of EVENTS) {
    const groups = settings.hooks[event];
    if (Array.isArray(groups)) {
      const cleaned = stripOurs(groups);
      if (cleaned.length) settings.hooks[event] = cleaned;
      else delete settings.hooks[event];
    }
  }

  // Remove our statusLine too (only if it is ours).
  if (
    settings.statusLine &&
    typeof settings.statusLine.command === "string" &&
    settings.statusLine.command.includes(STATUSLINE_MARKER)
  ) {
    delete settings.statusLine;
  }

  if (uninstall) {
    if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
    console.log(`✓ Removed Agents-HUD hooks + statusLine from ${settingsPath}`);
    return;
  }

  // Back up before writing changes.
  if (fs.existsSync(settingsPath)) {
    const backup = settingsPath + ".cc-signal.bak";
    fs.copyFileSync(settingsPath, backup);
    console.log(`• Backed up existing settings to ${backup}`);
  }

  const entry = {
    matcher: "*",
    hooks: [
      {
        type: "command",
        command: scriptPath,
        args: [String(cfg.port)],
        async: true,
        timeout: 5,
      },
    ],
  };

  for (const event of EVENTS) {
    const groups = Array.isArray(settings.hooks[event]) ? settings.hooks[event] : [];
    groups.push(JSON.parse(JSON.stringify(entry)));
    settings.hooks[event] = groups;
  }

  // Install the statusLine bridge (this is what delivers Claude's REAL plan
  // usage % and reset time). Don't clobber a pre-existing custom statusLine.
  let statusInstalled = false;
  if (settings.statusLine && typeof settings.statusLine === "object") {
    console.warn(
      `! Existing statusLine detected — leaving it untouched.\n` +
        `  To get real plan usage, set statusLine.command to:\n  ${statusPath} ${cfg.port}`,
    );
  } else {
    settings.statusLine = {
      type: "command",
      command: `${statusPath} ${cfg.port}`,
      padding: 0,
    };
    statusInstalled = true;
  }

  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
  console.log(`✓ Installed Agents-HUD hooks into ${settingsPath}`);
  console.log(`  Hook script : ${scriptPath}`);
  console.log(`  Port        : ${cfg.port}`);
  console.log(`  Events      : ${EVENTS.join(", ")}`);
  console.log(`  statusLine  : ${statusInstalled ? statusPath : "(kept existing — see warning above)"}`);
  console.log("\n  Restart any running Claude Code sessions to pick up the changes.");
}

main();
