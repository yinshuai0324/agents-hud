#!/usr/bin/env node
// Generates the golden wire fixture for the Swift port's unit tests by running
// the ORIGINAL Node implementation over the synthetic transcripts in
// mac/Tests/AgentsHUDCoreTests/Fixtures/claude-home.
//
//   node scripts/gen-golden.mjs
//
// Rerun after changing the fixtures; commit the resulting golden.json.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "..");
const fixtures = path.join(repo, "mac", "Tests", "AgentsHUDCoreTests", "Fixtures");
const claudeHome = path.join(fixtures, "claude-home");

process.env.CC_SIGNAL_CLAUDE_DIR = claudeHome;

const { loadConfig } = await import(path.join(repo, "server/dist/config.js"));
const { ClaudeProvider } = await import(path.join(repo, "server/dist/providers/claude.js"));
const { computeUsage5h } = await import(path.join(repo, "server/dist/usage5h.js"));
const { computeTodayUsage } = await import(path.join(repo, "server/dist/today.js"));

// Fixed "now" inside the fixtures' active 5h window (events 10:00–11:30 UTC).
const NOW = Date.parse("2026-01-02T12:00:00.000Z");

const cfg = loadConfig();
const provider = new ClaudeProvider(cfg);
const snap = await provider.collect();

// Sessions without timestamps fall back to file mtime, which changes per
// checkout — zero those fields so the golden stays deterministic.
const TIMELESS = new Set(["s3"]);
const sessions = snap.sessions
  .map((s) => ({
    ...s,
    lastActivity: TIMELESS.has(s.id) ? 0 : s.lastActivity,
    firstActivity: TIMELESS.has(s.id) ? 0 : s.firstActivity,
  }))
  .sort((a, b) => a.id.localeCompare(b.id));

const usageEvents = [...snap.usageEvents].sort((a, b) => a.ts - b.ts || a.tokens - b.tokens);

const golden = {
  now: NOW,
  sessions,
  usageEvents,
  usage5h: computeUsage5h(snap.usageEvents, cfg, NOW),
  today: await computeTodayUsage(cfg, NOW),
};

const out = path.join(fixtures, "golden.json");
fs.writeFileSync(out, JSON.stringify(golden, null, 2) + "\n");
console.log(`wrote ${out}`);
console.log(JSON.stringify(golden, null, 2));
