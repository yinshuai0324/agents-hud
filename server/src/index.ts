#!/usr/bin/env node
import { loadConfig } from "./config.js";
import { ClaudeProvider } from "./providers/claude.js";
import { StateEngine } from "./state.js";
import { createServer } from "./server.js";
import { buildPairing, printPairingQr } from "./qr.js";

async function main() {
  const cfg = loadConfig();
  const providers = [new ClaudeProvider(cfg)];
  const engine = new StateEngine(cfg, providers);
  await engine.start();

  const server = createServer(cfg, engine);
  server.listen(cfg.port, cfg.host, () => {
    console.clear();
    console.log("┌──────────────────────────────────────────────┐");
    console.log("│                   AgentsHUD                    │");
    console.log("└──────────────────────────────────────────────┘");
    const pairing = buildPairing(cfg.port, cfg.authToken);
    printPairingQr(pairing);
    console.log(`   Listening on ${cfg.host}:${cfg.port}`);
    console.log(`   Watching    ${cfg.projectsDir}`);
    console.log(`   5H budget   ${cfg.tokenBudget.toLocaleString()} tokens (basis: ${cfg.percentBasis})`);
    console.log("\n   Tip: run `npm run setup-hooks` once for accurate live status.\n");
  });

  const shutdown = () => {
    engine.stop();
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 500);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((err) => {
  console.error("Fatal:", err);
  process.exit(1);
});
