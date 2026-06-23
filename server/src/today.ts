import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";
import type { Config } from "./config.js";
import { costFor, type TokenCounts } from "./pricing.js";

/** Today's spend, summed across every session, by local-day message timestamps. */
export interface TodayUsage {
  /** Conversation tokens today: input + output (the "real work" you typed/got). */
  tokens: number;
  /** Cache-write tokens today (prompt caching). Usually dwarfs `tokens`. */
  cacheWriteTokens: number;
  /** Equivalent pay-as-you-go cost in USD (billing-accurate; includes cache read). */
  costUSD: number;
}

/** Local midnight (start of today) as epoch ms. */
function startOfTodayLocal(now: number): number {
  const d = new Date(now);
  d.setHours(0, 0, 0, 0);
  return d.getTime();
}

function emptyCounts(): TokenCounts {
  return { input: 0, output: 0, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0 };
}

/**
 * Accurately tally today's token spend.
 *
 * Unlike the live session collector, this scans *all* transcripts (not just
 * ones active within dropAfterMs) so a session that finished hours ago this
 * morning still counts. Files untouched since before midnight are skipped —
 * they can't contain a message timestamped today. Within each file, messages
 * are filtered by their own `timestamp` (not the file mtime, which can be
 * bumped by an unrelated write), deduped by `message.id` (one assistant turn
 * spans several JSONL lines repeating the same usage), and priced per model.
 */
export async function computeTodayUsage(cfg: Config, now = Date.now()): Promise<TodayUsage> {
  const dayStart = startOfTodayLocal(now);
  const byModel = new Map<string, TokenCounts>();
  const counted = new Set<string>();

  let dirEntries: fs.Dirent[];
  try {
    dirEntries = await fsp.readdir(cfg.projectsDir, { withFileTypes: true });
  } catch {
    return { tokens: 0, cacheWriteTokens: 0, costUSD: 0 };
  }

  for (const projDir of dirEntries) {
    if (!projDir.isDirectory()) continue;
    const dirPath = path.join(cfg.projectsDir, projDir.name);
    let files: string[];
    try {
      files = await fsp.readdir(dirPath);
    } catch {
      continue;
    }
    for (const file of files) {
      if (!file.endsWith(".jsonl")) continue;
      const full = path.join(dirPath, file);
      try {
        // A file not written since before midnight has no messages from today.
        if ((await fsp.stat(full)).mtimeMs < dayStart) continue;
      } catch {
        continue;
      }
      await scanFile(full, dayStart, byModel, counted);
    }
  }

  let tokens = 0;
  let cacheWriteTokens = 0;
  let costUSD = 0;
  for (const [model, c] of byModel) {
    tokens += c.input + c.output;
    cacheWriteTokens += c.cacheWrite5m + c.cacheWrite1h;
    costUSD += costFor(model, c);
  }
  return { tokens, cacheWriteTokens, costUSD };
}

async function scanFile(
  filePath: string,
  dayStart: number,
  byModel: Map<string, TokenCounts>,
  counted: Set<string>,
): Promise<void> {
  let stream: fs.ReadStream;
  try {
    stream = fs.createReadStream(filePath, { encoding: "utf8" });
  } catch {
    return;
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
      if (d.type !== "assistant" || !d.message) continue;
      const ts = typeof d.timestamp === "string" ? Date.parse(d.timestamp) : NaN;
      if (!Number.isFinite(ts) || ts < dayStart) continue;
      const u = d.message.usage;
      if (!u) continue;
      const id = typeof d.message.id === "string" ? d.message.id : "";
      if (id) {
        if (counted.has(id)) continue;
        counted.add(id);
      }
      const model = typeof d.message.model === "string" ? d.message.model : "unknown";
      let c = byModel.get(model);
      if (!c) {
        c = emptyCounts();
        byModel.set(model, c);
      }
      c.input += Number(u.input_tokens) || 0;
      c.output += Number(u.output_tokens) || 0;
      c.cacheRead += Number(u.cache_read_input_tokens) || 0;
      // Split cache writes by TTL when the breakdown is present; otherwise the
      // whole amount defaults to the 5-minute tier (Claude Code's default).
      const cc = u.cache_creation;
      const w5 = Number(cc?.ephemeral_5m_input_tokens);
      const w1 = Number(cc?.ephemeral_1h_input_tokens);
      if (Number.isFinite(w5) || Number.isFinite(w1)) {
        c.cacheWrite5m += Number.isFinite(w5) ? w5 : 0;
        c.cacheWrite1h += Number.isFinite(w1) ? w1 : 0;
      } else {
        c.cacheWrite5m += Number(u.cache_creation_input_tokens) || 0;
      }
    }
  } catch {
    // partial/locked file — keep whatever we read
  } finally {
    rl.close();
    stream.close();
  }
}
