import fs from "node:fs";
import path from "node:path";
import type { Config } from "./config.js";
import type { Provider, SessionData, SessionState } from "./providers/types.js";
import { computeUsage5h, type Usage5h } from "./usage5h.js";
import { computeTodayUsage, type TodayUsage } from "./today.js";
import { resolvePlan } from "./plan.js";

/** A secondary usage window (e.g. weekly), shown alongside the 5h gauge. */
export interface UsageWindow {
  percent: number;
  resetInMinutes: number;
}

/** Wire format pushed to clients. Keep in sync with the Android Snapshot model. */
export interface Snapshot {
  provider: string;
  /** Subscription plan display name, e.g. "Max (5x)". Empty if unknown. */
  plan: string;
  /** Model of the most recently active session, e.g. "Opus 4.8 (1M)". "" if unknown. */
  model: string;
  status: {
    waiting: number;
    working: number;
    quiet: number;
    notify: number;
    error: number;
    dominant: SessionState;
    total: number;
  };
  usage5h: Usage5h;
  /** Weekly (7-day) limit from Claude, when available; otherwise null. */
  usage7d: UsageWindow | null;
  /** Today's total spend across all sessions (local-day), tokens + equiv. USD. */
  today: TodayUsage;
  sessions: WireSession[];
  /** Live output generation speed (tokens/sec) of the fastest streaming session. */
  outputTokensPerSec: number;
  ts: string;
}

export interface WireSession {
  id: string;
  project: string;
  cwd: string;
  state: SessionState;
  model: string;
  lastActivity: number;
  tokens: number;
  /** Current context occupancy in tokens (0 if unknown). */
  contextTokens: number;
  /** Estimated context window remaining, 0–100 (0 if unknown). */
  contextLeftPercent: number;
  /** Tool currently/most-recently invoked while working, "" if none. */
  currentTool: string;
}

/**
 * Context window guess: the transcript doesn't record whether the 1M beta is on,
 * so once a session's occupancy exceeds the 200k base it must be a 1M window.
 */
function contextWindowFor(contextTokens: number): number {
  return contextTokens > 200_000 ? 1_000_000 : 200_000;
}

interface Runtime {
  state: SessionState;
  /** Last time any activity signal arrived (hook or file write). */
  lastSignalAt: number;
  /** When the session entered the "waiting" state (for the quiet timeout). */
  waitingSince: number;
  /** Once a hook is seen for a session, hooks drive its state authoritatively. */
  hookMode: boolean;
  /** Tool currently/most-recently invoked this turn (from PreToolUse), "" if none. */
  currentTool: string;
}

/** Map a Claude Code hook event name to a coarse activity signal. */
function hookToSignal(
  event: string,
): "working" | "waiting" | "notify" | "error" | "end" | null {
  switch (event) {
    case "UserPromptSubmit":
    case "PreToolUse":
    case "PostToolUse":
    case "PostToolBatch":
    case "SessionStart":
      return "working";
    case "Stop":
      return "waiting";
    case "Notification":
      return "notify";
    case "StopFailure":
      return "error";
    case "SessionEnd":
      return "end";
    default:
      return null;
  }
}

interface LiveWindow {
  percent: number;
  resetsAt: number | null; // epoch ms
  ts: number; // when received
}

/** Per-session info harvested from that session's statusLine payload. */
interface LiveSession {
  name: string;
  model: string; // pretty display_name from statusLine, "" if unknown
  ctxLeft: number; // remaining_percentage, or -1 if unknown
  ctxTokens: number; // current context occupancy, or 0
  ts: number;
  // Output-speed tracking: the current turn's output_tokens and when it was
  // sampled, plus the most recent computed tok/s.
  outputTokens: number;
  outAt: number;
  outTokPerSec: number;
}

/** Output-speed sampling window, mirroring claude-hud's speed-tracker. */
const SPEED_MAX_DELTA_MS = 4000;
const SPEED_MIN_DELTA_MS = 500;

/** Friendly model name from a raw id, e.g. "claude-opus-4-8[1m]" -> "Opus 4.8 (1M)". */
function prettyModel(id: string): string {
  if (!id) return "";
  const oneM = /\[1m\]$/i.test(id);
  let s = id.replace(/\[1m\]$/i, "").replace(/-\d{8}$/, "").replace(/^claude-/, "");
  const m = s.match(/^(opus|sonnet|haiku|fable)-(\d+)-(\d+)/i);
  if (m) {
    const fam = m[1]!;
    s = `${fam[0]!.toUpperCase()}${fam.slice(1)} ${m[2]}.${m[3]}`;
  }
  return oneM ? `${s} (1M)` : s;
}

/** Real statusLine usage is trusted for this long before falling back to estimate. */
const LIVE_TTL_MS = 20 * 60_000;

/**
 * A live rate-limit window stays valid until it actually resets — the percentage
 * is meaningful for the whole window, not just for [LIVE_TTL_MS]. Without a known
 * reset time we fall back to the short TTL. This keeps the real 5h/7d numbers on
 * screen across an idle stretch or a reconnect instead of dropping to estimate.
 */
function liveWindowValid(w: LiveWindow | null, now: number): boolean {
  if (!w) return false;
  if (w.resetsAt != null) return now < w.resetsAt;
  return now - w.ts < LIVE_TTL_MS;
}

export class StateEngine {
  private runtimes = new Map<string, Runtime>();
  private sessions = new Map<string, SessionData>();
  private usageEvents: { ts: number; tokens: number }[] = [];
  private listeners = new Set<(s: Snapshot) => void>();
  private lastJson = "";
  private disposers: Array<() => void> = [];
  private liveFiveHour: LiveWindow | null = null;
  private liveSevenDay: LiveWindow | null = null;
  private liveSessions = new Map<string, LiveSession>();
  /** Cached full-disk tally of today's spend; refreshed on a slow timer. */
  private todayUsage: TodayUsage = { tokens: 0, cacheWriteTokens: 0, costUSD: 0 };

  constructor(
    private cfg: Config,
    private providers: Provider[],
  ) {}

  /** Where the last-known live rate limits are cached across restarts. */
  private get usageCachePath(): string {
    return path.join(this.cfg.claudeDir, ".agentshud-usage.json");
  }

  /** Restore the cached 5h/7d windows so a restart doesn't blank them out. */
  private loadUsageCache(): void {
    try {
      const raw = fs.readFileSync(this.usageCachePath, "utf8");
      const d = JSON.parse(raw);
      if (d?.fiveHour) this.liveFiveHour = d.fiveHour;
      if (d?.sevenDay) this.liveSevenDay = d.sevenDay;
    } catch {
      // no cache yet / unreadable — fine, we'll rebuild from the next statusLine
    }
  }

  private saveUsageCache(): void {
    try {
      const data = JSON.stringify({ fiveHour: this.liveFiveHour, sevenDay: this.liveSevenDay });
      fs.writeFileSync(this.usageCachePath, data);
    } catch {
      // best-effort; never let caching break the request path
    }
  }

  onSnapshot(fn: (s: Snapshot) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  async start(): Promise<void> {
    this.loadUsageCache();
    await this.refresh();
    for (const p of this.providers) {
      this.disposers.push(p.watch((id) => this.onFileChange(id)));
    }
    // Periodic refresh: picks up token totals, new/removed sessions, and runs
    // the idle-timeout transitions.
    const refreshTimer = setInterval(() => void this.refresh(), 3000);
    const tickTimer = setInterval(() => this.tickAndEmit(), 1000);
    this.disposers.push(() => clearInterval(refreshTimer));
    this.disposers.push(() => clearInterval(tickTimer));
    // Today's spend is a full-disk scan, so compute it on a slower cadence and
    // cache the result for the snapshot. Runs once now, then every 30s.
    void this.refreshTodayUsage();
    const todayTimer = setInterval(() => void this.refreshTodayUsage(), 30_000);
    this.disposers.push(() => clearInterval(todayTimer));
  }

  stop(): void {
    for (const d of this.disposers) d();
    this.disposers = [];
  }

  /** Recompute today's spend from disk and push if it moved the snapshot. */
  private async refreshTodayUsage(): Promise<void> {
    try {
      this.todayUsage = await computeTodayUsage(this.cfg);
    } catch {
      return; // keep the last good value
    }
    this.tickAndEmit();
  }

  /** Re-read all providers from disk and reconcile runtime state. */
  private async refresh(): Promise<void> {
    const now = Date.now();
    const seen = new Set<string>();
    const allEvents: { ts: number; tokens: number }[] = [];
    for (const p of this.providers) {
      let snap;
      try {
        snap = await p.collect();
      } catch {
        continue;
      }
      allEvents.push(...snap.usageEvents);
      for (const s of snap.sessions) {
        seen.add(s.id);
        this.sessions.set(s.id, s);
        if (!this.runtimes.has(s.id)) {
          this.runtimes.set(s.id, this.initialRuntime(s, now));
        }
      }
    }
    this.usageEvents = allEvents;
    // Drop sessions the providers no longer report (aged out beyond dropAfterMs).
    for (const id of [...this.sessions.keys()]) {
      if (!seen.has(id)) {
        this.sessions.delete(id);
        this.runtimes.delete(id);
        this.liveSessions.delete(id);
      }
    }
    this.tickAndEmit();
  }

  /**
   * Called by the HTTP /statusline endpoint with the JSON Claude Code pipes to a
   * statusLine command. We harvest the real `rate_limits` (five_hour/seven_day)
   * which originate from Claude's own /api/oauth/usage — no credentials touched.
   */
  handleStatusline(data: any): void {
    const now = Date.now();

    // Per-session info: title + Claude's own context-window numbers.
    const sid = String(data?.session_id ?? "");
    if (sid) {
      const cw = data?.context_window;
      let ctxTokens = Number(cw?.total_input_tokens) || 0;
      if (!ctxTokens && cw?.current_usage) {
        const u = cw.current_usage;
        ctxTokens =
          (Number(u.input_tokens) || 0) +
          (Number(u.cache_creation_input_tokens) || 0) +
          (Number(u.cache_read_input_tokens) || 0);
      }
      const ctxLeft = Number.isFinite(cw?.remaining_percentage)
        ? clampPct(cw.remaining_percentage)
        : -1;
      const modelName =
        typeof data?.model?.display_name === "string"
          ? data.model.display_name
          : prettyModel(String(data?.model?.id ?? ""));

      // Output speed (tok/s): the rate the current turn's output_tokens grows
      // between statusLine updates. Mirrors claude-hud's speed-tracker.
      const outNow = Number(cw?.current_usage?.output_tokens) || 0;
      const prev = this.liveSessions.get(sid);
      let outputTokens = outNow;
      let outAt = now;
      let outTokPerSec = 0;
      if (prev) {
        const dMs = now - prev.outAt;
        if (outNow < prev.outputTokens) {
          // Counter went backwards → a new turn started; reset the baseline.
          outTokPerSec = 0;
        } else if (dMs < SPEED_MIN_DELTA_MS) {
          // Too soon to measure reliably; keep accumulating from the old sample.
          outputTokens = prev.outputTokens;
          outAt = prev.outAt;
          outTokPerSec = prev.outTokPerSec;
        } else if (dMs <= SPEED_MAX_DELTA_MS && outNow > prev.outputTokens) {
          outTokPerSec = Math.round((outNow - prev.outputTokens) / (dMs / 1000));
        }
        // dMs > SPEED_MAX_DELTA_MS with no growth → stale; reset (speed 0).
      }

      this.liveSessions.set(sid, {
        name: typeof data?.session_name === "string" ? data.session_name : "",
        model: modelName,
        ctxLeft,
        ctxTokens,
        ts: now,
        outputTokens,
        outAt,
        outTokPerSec,
      });
    }

    const rl = data?.rate_limits;
    if (!rl) {
      this.tickAndEmit();
      return;
    }
    if (rl.five_hour) {
      this.liveFiveHour = {
        percent: clampPct(rl.five_hour.used_percentage),
        resetsAt: parseReset(rl.five_hour.resets_at),
        ts: now,
      };
    }
    if (rl.seven_day) {
      this.liveSevenDay = {
        percent: clampPct(rl.seven_day.used_percentage),
        resetsAt: parseReset(rl.seven_day.resets_at),
        ts: now,
      };
    }
    if (rl.five_hour || rl.seven_day) this.saveUsageCache();
    this.tickAndEmit();
  }

  private initialRuntime(s: SessionData, now: number): Runtime {
    const age = now - s.lastActivity;
    let state: SessionState;
    if (age < this.cfg.workingTimeoutMs) state = "working";
    else if (age < this.cfg.quietAfterMs) state = "waiting";
    else state = "quiet";
    return {
      state,
      lastSignalAt: s.lastActivity,
      waitingSince: state === "waiting" ? s.lastActivity : 0,
      hookMode: false,
      currentTool: "",
    };
  }

  /** Called by the HTTP /hooks endpoint. */
  handleHook(event: string, sessionId: string, cwd?: string, toolName?: string): void {
    if (!sessionId) return;
    const signal = hookToSignal(event);
    if (signal === null) return;
    const now = Date.now();

    if (signal === "end") {
      // Treat as quiet immediately; refresh() will drop it once aged out.
      const rt = this.runtimes.get(sessionId);
      if (rt) {
        rt.state = "quiet";
        rt.currentTool = "";
        rt.hookMode = true;
      }
      this.tickAndEmit();
      return;
    }

    let rt = this.runtimes.get(sessionId);
    if (!rt) {
      rt = { state: "quiet", lastSignalAt: now, waitingSince: 0, hookMode: true, currentTool: "" };
      this.runtimes.set(sessionId, rt);
      // Create a placeholder session so it shows up before disk catches up.
      if (!this.sessions.has(sessionId)) {
        this.sessions.set(sessionId, this.placeholderSession(sessionId, cwd ?? ""));
      }
    }
    rt.hookMode = true;
    rt.lastSignalAt = now;
    if (signal === "working") {
      rt.state = "working";
      rt.waitingSince = 0;
    } else {
      // waiting | notify | error — the signal value is also the state name.
      rt.state = signal;
      rt.waitingSince = now;
    }
    // Track the live tool: set on PreToolUse, keep it through PostToolUse, and
    // clear it on anything that ends the tool run (new prompt / stop / notify).
    if (event === "PreToolUse") {
      if (toolName) rt.currentTool = toolName;
    } else if (event !== "PostToolUse" && event !== "PostToolBatch") {
      rt.currentTool = "";
    }
    const s = this.sessions.get(sessionId);
    if (s) {
      // Any hook signal is fresh activity — bump lastActivity so a new state
      // (e.g. an approval prompt) moves this session to the top of the list,
      // which is what now drives the traffic light.
      s.lastActivity = now;
      if (cwd && !s.cwd) {
        s.cwd = cwd;
        s.project = cwd.split("/").filter(Boolean).slice(-3).join("/") || s.project;
      }
    }
    this.tickAndEmit();
  }

  private placeholderSession(id: string, cwd: string): SessionData {
    return {
      id,
      provider: this.providers[0]?.name ?? "claude",
      cwd,
      project: cwd ? cwd.split("/").filter(Boolean).slice(-3).join("/") : "…",
      model: "",
      lastActivity: Date.now(),
      firstActivity: Date.now(),
      usage: { input: 0, output: 0, cacheCreate: 0, cacheRead: 0, total: 0 },
      contextTokens: 0,
    };
  }

  /** File write detected by a provider watcher. */
  private onFileChange(sessionId: string | null): void {
    if (!sessionId) {
      void this.refresh();
      return;
    }
    const rt = this.runtimes.get(sessionId);
    const now = Date.now();
    if (!rt) {
      // Unknown session: let refresh() discover it.
      void this.refresh();
      return;
    }
    const s = this.sessions.get(sessionId);
    if (s) s.lastActivity = now;
    // In hook mode, hooks own the state; a file write only refreshes activity.
    if (rt.hookMode) {
      rt.lastSignalAt = now;
      this.tickAndEmit();
      return;
    }
    rt.state = "working";
    rt.lastSignalAt = now;
    rt.waitingSince = 0;
    this.tickAndEmit();
  }

  /** Apply idle-timeout transitions, then emit if the snapshot changed. */
  private tickAndEmit(): void {
    const now = Date.now();
    for (const rt of this.runtimes.values()) {
      if (rt.state === "working" && now - rt.lastSignalAt > this.cfg.workingTimeoutMs) {
        rt.state = "waiting";
        rt.waitingSince = now;
        rt.currentTool = "";
      }
      if (rt.state === "waiting" && now - rt.waitingSince > this.cfg.quietAfterMs) {
        rt.state = "quiet";
      }
    }
    const snap = this.buildSnapshot(now);
    const json = JSON.stringify({ ...snap, ts: undefined });
    if (json === this.lastJson) return; // no semantic change; skip push
    this.lastJson = json;
    for (const fn of this.listeners) fn(snap);
  }

  buildSnapshot(now = Date.now()): Snapshot {
    let waiting = 0;
    let working = 0;
    let quiet = 0;
    let notify = 0;
    let error = 0;
    const wire: WireSession[] = [];
    for (const [id, s] of this.sessions) {
      const rt = this.runtimes.get(id);
      const state = rt?.state ?? "quiet";
      if (state === "waiting") waiting++;
      else if (state === "working") working++;
      else if (state === "notify") notify++;
      else if (state === "error") error++;
      else quiet++;
      // Prefer Claude's own statusLine numbers/title for this session when fresh.
      const live = this.liveSessions.get(id);
      const liveFresh = !!live && now - live.ts < LIVE_TTL_MS;
      const ctx = liveFresh && live!.ctxTokens > 0 ? live!.ctxTokens : s.contextTokens || 0;
      const contextLeftPercent =
        liveFresh && live!.ctxLeft >= 0
          ? live!.ctxLeft
          : ctx > 0
            ? Math.max(0, Math.round((1 - ctx / contextWindowFor(ctx)) * 100))
            : 0;
      const project = liveFresh && live!.name ? live!.name : s.project;
      wire.push({
        id,
        project,
        cwd: s.cwd,
        state,
        model: s.model,
        lastActivity: s.lastActivity,
        tokens: s.usage.total,
        contextTokens: ctx,
        contextLeftPercent,
        currentTool: state === "working" ? rt?.currentTool ?? "" : "",
      });
    }
    wire.sort((a, b) => b.lastActivity - a.lastActivity);

    // Current model = the most recently active session's model (pretty name from
    // its statusLine if fresh, else derived from the transcript model id).
    let currentModel = "";
    const top = wire[0];
    if (top) {
      const live = this.liveSessions.get(top.id);
      currentModel =
        live && live.model && now - live.ts < LIVE_TTL_MS ? live.model : prettyModel(top.model);
    }

    // Live output speed: the fastest session still actively streaming.
    let outputTokensPerSec = 0;
    for (const live of this.liveSessions.values()) {
      if (now - live.ts <= SPEED_MAX_DELTA_MS && live.outTokPerSec > outputTokensPerSec) {
        outputTokensPerSec = live.outTokPerSec;
      }
    }

    // Follow the most recently active session (wire is sorted newest-first), so
    // the latest state change always drives the light — instead of a fixed
    // priority that would stick on an old approval/error until it cleared.
    const dominant: SessionState = top?.state ?? "quiet";

    // Prefer Claude's real 5h numbers (from statusLine) over the local estimate.
    let usage5h: Usage5h = computeUsage5h(this.usageEvents, this.cfg, now);
    if (liveWindowValid(this.liveFiveHour, now)) {
      usage5h = {
        ...usage5h,
        percent: this.liveFiveHour!.percent,
        resetInMinutes: minutesUntil(this.liveFiveHour!.resetsAt, now) ?? usage5h.resetInMinutes,
        source: "live",
      };
    }

    let usage7d: UsageWindow | null = null;
    if (liveWindowValid(this.liveSevenDay, now)) {
      usage7d = {
        percent: this.liveSevenDay!.percent,
        resetInMinutes: minutesUntil(this.liveSevenDay!.resetsAt, now) ?? 0,
      };
    }

    return {
      provider: this.providers[0]?.name ?? "claude",
      plan: resolvePlan(),
      model: currentModel,
      status: {
        waiting,
        working,
        quiet,
        notify,
        error,
        dominant,
        total: waiting + working + quiet + notify + error,
      },
      usage5h,
      usage7d,
      today: this.todayUsage,
      sessions: wire,
      outputTokensPerSec,
      ts: new Date(now).toISOString(),
    };
  }
}

/** Parse a rate-limit reset value: ISO string, epoch seconds, or epoch ms. */
function parseReset(v: unknown): number | null {
  if (v == null) return null;
  if (typeof v === "number") return v > 1e12 ? v : v * 1000; // s -> ms heuristic
  if (typeof v === "string") {
    const n = Number(v);
    if (Number.isFinite(n)) return n > 1e12 ? n : n * 1000;
    const t = Date.parse(v);
    return Number.isNaN(t) ? null : t;
  }
  return null;
}

function minutesUntil(resetsAt: number | null, now: number): number | null {
  if (resetsAt == null) return null;
  return Math.max(0, Math.round((resetsAt - now) / 60_000));
}

function clampPct(v: unknown): number {
  const n = Number(v);
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(100, Math.round(n)));
}
