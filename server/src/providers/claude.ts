import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";
import type { Config } from "../config.js";
import {
  emptyUsage,
  type Provider,
  type ProviderSnapshot,
  type SessionData,
  type TokenUsage,
  type UsageEvent,
} from "./types.js";

/** Short label from the last 3 path segments, e.g. /a/b/c/d/e -> "c/d/e". */
function projectLabel(cwd: string): string {
  if (!cwd) return "unknown";
  const parts = cwd.split(path.sep).filter(Boolean);
  return parts.slice(-3).join("/") || cwd;
}

function addUsage(into: TokenUsage, u: any): number {
  const input = Number(u?.input_tokens) || 0;
  const output = Number(u?.output_tokens) || 0;
  const cacheCreate = Number(u?.cache_creation_input_tokens) || 0;
  const cacheRead = Number(u?.cache_read_input_tokens) || 0;
  into.input += input;
  into.output += output;
  into.cacheCreate += cacheCreate;
  into.cacheRead += cacheRead;
  const newWork = input + output + cacheCreate;
  into.total += newWork;
  return newWork;
}

/**
 * Reads Claude Code session transcripts from ~/.claude/projects and exposes them
 * as provider sessions + timestamped usage events.
 */
export class ClaudeProvider implements Provider {
  readonly name = "claude";
  constructor(private cfg: Config) {}

  async collect(): Promise<ProviderSnapshot> {
    const sessions: SessionData[] = [];
    const usageEvents: UsageEvent[] = [];
    let dirEntries: fs.Dirent[];
    try {
      dirEntries = await fsp.readdir(this.cfg.projectsDir, { withFileTypes: true });
    } catch {
      return { sessions, usageEvents };
    }

    const now = Date.now();
    for (const projDir of dirEntries) {
      if (!projDir.isDirectory()) continue;
      const dirPath = path.join(this.cfg.projectsDir, projDir.name);
      let files: string[];
      try {
        files = await fsp.readdir(dirPath);
      } catch {
        continue;
      }
      for (const file of files) {
        if (!file.endsWith(".jsonl")) continue;
        const full = path.join(dirPath, file);
        let stat: fs.Stats;
        try {
          stat = await fsp.stat(full);
        } catch {
          continue;
        }
        // Skip sessions that have been inactive for longer than the drop window;
        // they are neither shown nor counted toward the live 5h block.
        if (now - stat.mtimeMs > this.cfg.dropAfterMs) continue;
        const session = await this.parseFile(full, file.replace(/\.jsonl$/, ""), usageEvents);
        if (session) sessions.push(session);
      }
    }
    return { sessions, usageEvents };
  }

  private async parseFile(
    filePath: string,
    sessionId: string,
    usageEvents: UsageEvent[],
  ): Promise<SessionData | null> {
    const usage = emptyUsage();
    let cwd = "";
    let model = "";
    let first = Number.POSITIVE_INFINITY;
    let last = 0;
    let sawAny = false;
    // Current context occupancy = the most recent request's input + cache. The
    // last assistant message wins (transcript is chronological).
    let contextTokens = 0;

    let stream: fs.ReadStream;
    try {
      stream = fs.createReadStream(filePath, { encoding: "utf8" });
    } catch {
      return null;
    }
    const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
    try {
      for await (const line of rl) {
        const trimmed = line.trim();
        if (!trimmed) continue;
        let d: any;
        try {
          d = JSON.parse(trimmed);
        } catch {
          continue;
        }
        if (typeof d.cwd === "string" && d.cwd) cwd = d.cwd;
        const ts = typeof d.timestamp === "string" ? Date.parse(d.timestamp) : NaN;
        if (Number.isFinite(ts)) {
          sawAny = true;
          if (ts < first) first = ts;
          if (ts > last) last = ts;
        }
        if (d.type === "assistant" && d.message) {
          if (typeof d.message.model === "string") model = d.message.model;
          const u = d.message.usage;
          if (u) {
            const newWork = addUsage(usage, u);
            if (Number.isFinite(ts) && newWork > 0) usageEvents.push({ ts, tokens: newWork });
            contextTokens =
              (Number(u.input_tokens) || 0) +
              (Number(u.cache_read_input_tokens) || 0) +
              (Number(u.cache_creation_input_tokens) || 0);
          }
        }
      }
    } catch {
      // partial/locked file — return whatever we managed to read
    } finally {
      rl.close();
      stream.close();
    }

    if (!sawAny) {
      // No timestamped content; fall back to file mtime so it still shows up.
      try {
        const st = fs.statSync(filePath);
        last = st.mtimeMs;
        first = st.birthtimeMs || st.mtimeMs;
      } catch {
        return null;
      }
    }

    return {
      id: sessionId,
      provider: this.name,
      cwd,
      project: projectLabel(cwd),
      model,
      lastActivity: last,
      firstActivity: Number.isFinite(first) ? first : last,
      usage,
      contextTokens,
    };
  }

  /**
   * Watches the projects directory recursively for transcript writes. macOS and
   * Windows support recursive fs.watch natively; on Linux we fall back to a
   * shallow watch plus polling handled by the caller's periodic refresh.
   */
  watch(onChange: (sessionId: string | null) => void): () => void {
    let watcher: fs.FSWatcher | null = null;
    try {
      watcher = fs.watch(
        this.cfg.projectsDir,
        { recursive: true },
        (_event, filename) => {
          if (!filename) return onChange(null);
          const name = filename.toString();
          if (!name.endsWith(".jsonl")) return;
          const base = path.basename(name).replace(/\.jsonl$/, "");
          onChange(base);
        },
      );
    } catch {
      // Recursive watch unsupported; caller's periodic refresh covers us.
      watcher = null;
    }
    return () => watcher?.close();
  }
}
