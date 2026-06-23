/**
 * Per-model API pricing, USD per 1,000,000 tokens. Subscription users don't pay
 * these directly — the "today cost" we show is the *equivalent* pay-as-you-go
 * cost of the tokens spent, the same figure tools like ccusage report.
 *
 * Cache tokens are priced off the model's input rate:
 *   - cache read     ≈ 0.1×  input
 *   - cache write 5m  = 1.25× input
 *   - cache write 1h  = 2.0×  input
 *
 * Rates are matched by family + version from the model id (date suffix and the
 * [1m] marker are stripped first). Unknown models fall back to Opus-tier rates
 * so the number errs high rather than silently undercounting.
 */
export interface ModelRate {
  /** USD per 1M input tokens. */
  input: number;
  /** USD per 1M output tokens. */
  output: number;
}

const CACHE_READ_MULT = 0.1;
const CACHE_WRITE_5M_MULT = 1.25;
const CACHE_WRITE_1H_MULT = 2.0;

/** family -> "major.minor" -> rate. Synthetic/internal messages cost nothing. */
const RATES: Array<{ test: RegExp; rate: ModelRate }> = [
  // Fable / Mythos 5
  { test: /^(fable|mythos)-5/, rate: { input: 10, output: 50 } },
  // Opus 4.5 / 4.6 / 4.7 / 4.8 — current Opus pricing
  { test: /^opus-4-(5|6|7|8)\b/, rate: { input: 5, output: 25 } },
  // Opus 4.0 / 4.1 / Opus 3 — legacy higher Opus pricing
  { test: /^opus-(4-(0|1)|3)\b/, rate: { input: 15, output: 75 } },
  // Sonnet 4.x / 3.7 / 3.5
  { test: /^sonnet-/, rate: { input: 3, output: 15 } },
  // Haiku 4.5
  { test: /^haiku-4/, rate: { input: 1, output: 5 } },
  // Haiku 3 / 3.5
  { test: /^haiku-3/, rate: { input: 0.8, output: 4 } },
];

/** Opus-tier fallback for unrecognized non-synthetic models. */
const FALLBACK: ModelRate = { input: 5, output: 25 };

/** Normalize a raw model id: drop `claude-` prefix, `[1m]` marker, date suffix. */
function normalize(id: string): string {
  return id
    .toLowerCase()
    .replace(/\[1m\]$/i, "")
    .replace(/-\d{8}$/, "")
    .replace(/^claude-/, "");
}

/** Resolve per-model rates. Returns null for synthetic/internal messages (free). */
export function rateFor(modelId: string): ModelRate | null {
  const id = normalize(modelId);
  if (!id || id.startsWith("<")) return null; // "<synthetic>" etc.
  for (const { test, rate } of RATES) {
    if (test.test(id)) return rate;
  }
  return FALLBACK;
}

/** Token counts for one model, split so cache tiers can be priced correctly. */
export interface TokenCounts {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite5m: number;
  cacheWrite1h: number;
}

/** Cost in USD for a model's token counts. Synthetic models cost 0. */
export function costFor(modelId: string, t: TokenCounts): number {
  const rate = rateFor(modelId);
  if (!rate) return 0;
  const inPerTok = rate.input / 1_000_000;
  const outPerTok = rate.output / 1_000_000;
  return (
    t.input * inPerTok +
    t.output * outPerTok +
    t.cacheRead * inPerTok * CACHE_READ_MULT +
    t.cacheWrite5m * inPerTok * CACHE_WRITE_5M_MULT +
    t.cacheWrite1h * inPerTok * CACHE_WRITE_1H_MULT
  );
}
