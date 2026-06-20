import os from "node:os";
import path from "node:path";

/**
 * Runtime configuration. Everything is overridable via environment variables so
 * the server can be tuned without editing code. Defaults are sensible for a
 * single-machine, single-LAN setup.
 */
export interface Config {
  /** TCP port for the HTTP + WebSocket server. */
  port: number;
  /** Bind address. 0.0.0.0 so phones on the LAN can reach it. */
  host: string;
  /** Absolute path to the ~/.claude directory. */
  claudeDir: string;
  /** Where Claude Code stores per-project session transcripts. */
  projectsDir: string;
  /**
   * Token budget used as the denominator for the "5H 用量 · X%" gauge. The true
   * subscription cap is not stored on disk, so this is configurable. When
   * `percentBasis` is "maxBlock" this value is only a fallback for the very
   * first block.
   */
  tokenBudget: number;
  /**
   * How the 5-hour percent is computed:
   *  - "budget":   tokensUsed / tokenBudget
   *  - "maxBlock": tokensUsed / max(historical 5h block, tokenBudget)
   */
  percentBasis: "budget" | "maxBlock";
  /** A session that has been "waiting" longer than this goes "quiet" (ms). */
  quietAfterMs: number;
  /**
   * A session with no file/hook activity for longer than this is dropped from
   * the live list entirely (ms).
   */
  dropAfterMs: number;
  /**
   * If a "working" session receives no further events for this long, we assume
   * the turn ended without a Stop hook and fall back to "waiting" (ms).
   */
  workingTimeoutMs: number;
  /** Optional shared secret. Empty string disables auth. */
  authToken: string;
}

function envInt(name: string, fallback: number): number {
  const raw = process.env[name];
  if (!raw) return fallback;
  const n = Number(raw);
  return Number.isFinite(n) ? n : fallback;
}

export function loadConfig(): Config {
  const claudeDir =
    process.env.CC_SIGNAL_CLAUDE_DIR || path.join(os.homedir(), ".claude");
  const basis = process.env.CC_SIGNAL_PERCENT_BASIS === "maxBlock" ? "maxBlock" : "budget";
  return {
    port: envInt("CC_SIGNAL_PORT", 4317),
    host: process.env.CC_SIGNAL_HOST || "0.0.0.0",
    claudeDir,
    projectsDir: path.join(claudeDir, "projects"),
    tokenBudget: envInt("CC_SIGNAL_TOKEN_BUDGET", 2_000_000),
    percentBasis: basis,
    quietAfterMs: envInt("CC_SIGNAL_QUIET_AFTER_MS", 5 * 60_000),
    dropAfterMs: envInt("CC_SIGNAL_DROP_AFTER_MS", 6 * 60 * 60_000),
    workingTimeoutMs: envInt("CC_SIGNAL_WORKING_TIMEOUT_MS", 90_000),
    authToken: process.env.CC_SIGNAL_TOKEN || "",
  };
}
