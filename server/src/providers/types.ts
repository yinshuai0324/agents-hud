/**
 * Lifecycle state of a single agent session.
 *  - working : actively running (prompt submitted / tools executing)
 *  - waiting : finished a turn, idle, your move
 *  - notify  : blocked on you (permission prompt / Notification)
 *  - error   : stopped on a failure (StopFailure)
 *  - quiet   : long-idle / abandoned
 * notify/error are only detectable in hook mode; the file-watch fallback can
 * only ever produce working/waiting/quiet.
 */
export type SessionState = "working" | "waiting" | "notify" | "error" | "quiet";

/** Token counters aggregated from a session's transcript. */
export interface TokenUsage {
  input: number;
  output: number;
  cacheCreate: number;
  cacheRead: number;
  /** input + output + cacheCreate (cacheRead excluded — it is not "new" work). */
  total: number;
}

/** A single coding-agent session as read from disk. */
export interface SessionData {
  /** Stable id (Claude session id == jsonl filename without extension). */
  id: string;
  /** Provider that owns this session, e.g. "claude". */
  provider: string;
  /** Absolute working directory of the session. */
  cwd: string;
  /** Short, human-friendly project label, e.g. "kaifa/fuwuqi". */
  project: string;
  /** Latest model id seen in the transcript. */
  model: string;
  /** Epoch ms of the last activity observed (file mtime / last message). */
  lastActivity: number;
  /** Epoch ms of the first message (used for the 5h block boundary). */
  firstActivity: number;
  usage: TokenUsage;
  /** Current context-window occupancy (last request's input + cache), 0 if unknown. */
  contextTokens: number;
}

/** A single timestamped chunk of token spend, used to build the 5-hour window. */
export interface UsageEvent {
  /** Epoch ms of the assistant message. */
  ts: number;
  /** Tokens counted toward the window (input + output + cacheCreate). */
  tokens: number;
}

/** Everything a provider reads from disk in one pass. */
export interface ProviderSnapshot {
  sessions: SessionData[];
  /** Per-message usage events across all sessions, for the 5h block math. */
  usageEvents: UsageEvent[];
}

/**
 * A pluggable source of agent sessions. Claude is the first implementation;
 * Gemini will implement the same interface so the rest of the stack is unchanged.
 */
export interface Provider {
  readonly name: string;
  /** Read the current sessions and usage events from disk in a single pass. */
  collect(): Promise<ProviderSnapshot>;
  /**
   * Watch the underlying data for changes. The callback receives the changed
   * session id (when known) so the state machine can refresh it. Returns a
   * disposer.
   */
  watch(onChange: (sessionId: string | null) => void): () => void;
  /**
   * Sum "new work" tokens (input + output + cacheCreate) across today and the
   * last 7 days, by scanning transcripts modified within the window. Optional —
   * the engine caches the result so it can scan a wider window than collect().
   */
  recentUsage?(now: number): Promise<{ today: number; sevenDay: number }>;
}

export function emptyUsage(): TokenUsage {
  return { input: 0, output: 0, cacheCreate: 0, cacheRead: 0, total: 0 };
}
