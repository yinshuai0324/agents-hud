import fs from "node:fs";
import os from "node:os";
import path from "node:path";

/**
 * Resolves the user's subscription plan display name (e.g. "Max (5x)") from
 * ~/.claude.json's oauthAccount.organizationRateLimitTier. Read-only; never
 * touches credentials. Cached briefly since the file rarely changes.
 */
const TIER_NAMES: Record<string, string> = {
  default_claude_max_20x: "Max (20x)",
  default_claude_max_5x: "Max (5x)",
  claude_pro: "Pro",
  default_claude_pro: "Pro",
  default_claude_zero: "Free",
};

function prettyTier(tier: string | null | undefined): string {
  if (!tier) return "";
  if (TIER_NAMES[tier]) return TIER_NAMES[tier]!;
  // Fallback: turn "default_claude_max_5x" -> "Max 5x"
  const m = tier.match(/max_(\d+)x/i);
  if (m) return `Max (${m[1]}x)`;
  if (/pro/i.test(tier)) return "Pro";
  if (/zero|free/i.test(tier)) return "Free";
  return tier;
}

let cache = { value: "", at: 0 };
const TTL_MS = 60_000;

export function resolvePlan(): string {
  const now = Date.now();
  if (now - cache.at < TTL_MS) return cache.value;
  let value = "";
  try {
    const file = path.join(os.homedir(), ".claude.json");
    const data = JSON.parse(fs.readFileSync(file, "utf8"));
    const acct = data?.oauthAccount;
    value = prettyTier(acct?.organizationRateLimitTier || acct?.userRateLimitTier);
  } catch {
    value = "";
  }
  cache = { value, at: now };
  return value;
}
