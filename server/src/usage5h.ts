import type { Config } from "./config.js";
import type { UsageEvent } from "./providers/types.js";

const FIVE_HOURS_MS = 5 * 60 * 60_000;

export interface Usage5h {
  /** 0..100, clamped. */
  percent: number;
  tokensUsed: number;
  tokenBudget: number;
  /** Minutes until the active block resets (0 if no active block). */
  resetInMinutes: number;
  /** ISO start/end of the active block, or null when idle. */
  blockStart: string | null;
  blockEnd: string | null;
  /** Tokens per minute over the active block so far. */
  burnRatePerMin: number;
  /**
   * "live"  = real numbers from Claude Code's statusLine rate_limits payload.
   * "estimate" = computed locally from token counts (fallback, approximate).
   */
  source: "live" | "estimate";
}

/** Floor a timestamp to the top of its hour (UTC) — ccusage block convention. */
function floorToHour(ts: number): number {
  return ts - (ts % (60 * 60_000));
}

/**
 * Groups timestamped usage into 5-hour billing windows (the ccusage "blocks"
 * model) and returns the currently active window.
 *
 * Algorithm: sort events by time; start a block at the first event floored to
 * the hour; an event belongs to the current block if it is within 5h of the
 * block start AND within 5h of the previous event (a >5h gap closes the block).
 * The active block is the last one whose end is still in the future.
 */
export function computeUsage5h(events: UsageEvent[], cfg: Config, now = Date.now()): Usage5h {
  const empty: Usage5h = {
    percent: 0,
    tokensUsed: 0,
    tokenBudget: cfg.tokenBudget,
    resetInMinutes: 0,
    blockStart: null,
    blockEnd: null,
    burnRatePerMin: 0,
    source: "estimate",
  };
  if (events.length === 0) return empty;

  const sorted = [...events].sort((a, b) => a.ts - b.ts);

  interface Block {
    start: number;
    end: number;
    lastTs: number;
    tokens: number;
  }
  const blocks: Block[] = [];
  let cur: Block | null = null;

  for (const ev of sorted) {
    if (
      cur &&
      ev.ts < cur.start + FIVE_HOURS_MS &&
      ev.ts - cur.lastTs < FIVE_HOURS_MS
    ) {
      cur.tokens += ev.tokens;
      cur.lastTs = ev.ts;
    } else {
      const start = floorToHour(ev.ts);
      cur = { start, end: start + FIVE_HOURS_MS, lastTs: ev.ts, tokens: ev.tokens };
      blocks.push(cur);
    }
  }

  // Active block: the most recent block whose 5h window has not yet elapsed.
  const active = blocks[blocks.length - 1];
  if (!active || now >= active.end) {
    // Most recent block has expired -> window reset, nothing active.
    const maxBlock = blocks.reduce((m, b) => Math.max(m, b.tokens), 0);
    return { ...empty, tokenBudget: budgetFor(cfg, maxBlock) };
  }

  const budget = budgetFor(cfg, maxOf(blocks, active));
  const resetInMinutes = Math.max(0, Math.round((active.end - now) / 60_000));
  const elapsedMin = Math.max(1, (now - active.start) / 60_000);
  return {
    percent: Math.min(100, Math.round((active.tokens / budget) * 100)),
    tokensUsed: active.tokens,
    tokenBudget: budget,
    resetInMinutes,
    blockStart: new Date(active.start).toISOString(),
    blockEnd: new Date(active.end).toISOString(),
    burnRatePerMin: Math.round(active.tokens / elapsedMin),
    source: "estimate",
  };
}

function maxOf(blocks: { tokens: number }[], exclude: { tokens: number }): number {
  return blocks.reduce((m, b) => (b === exclude ? m : Math.max(m, b.tokens)), 0);
}

/** Resolve the denominator for the percent gauge based on config. */
function budgetFor(cfg: Config, maxHistoricalBlock: number): number {
  if (cfg.percentBasis === "maxBlock") {
    return Math.max(cfg.tokenBudget, maxHistoricalBlock);
  }
  return cfg.tokenBudget;
}
