#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { loadConfig } from "./config.js";
import { ClaudeProvider } from "./providers/claude.js";
import { StateEngine } from "./state.js";
import { createServer } from "./server.js";
import { buildPairing, printPairingQr } from "./qr.js";

const SERVICE = "agents-hud";

function banner(): void {
  console.log("┌──────────────────────────────────────────────┐");
  console.log("│                   AgentsHUD                    │");
  console.log("└──────────────────────────────────────────────┘");
}

/** Default command: run the server in the foreground (launchd invokes this). */
async function serve(): Promise<void> {
  const cfg = loadConfig();
  const providers = [new ClaudeProvider(cfg)];
  const engine = new StateEngine(cfg, providers);
  await engine.start();

  const server = createServer(cfg, engine);
  server.listen(cfg.port, cfg.host, () => {
    console.clear();
    banner();
    printPairingQr(buildPairing(cfg.port, cfg.authToken));
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

/** Print the pairing QR + connection info without starting the server. */
function connect(): void {
  const cfg = loadConfig();
  banner();
  printPairingQr(buildPairing(cfg.port, cfg.authToken));
}

/** Delegate start/stop/restart/status to `brew services`. */
function brewService(action: string): number {
  const r = spawnSync("brew", ["services", action, SERVICE], { stdio: "inherit" });
  if (r.error) {
    console.error("无法调用 `brew services` —— 该命令需要通过 Homebrew 安装。");
    console.error("若是源码运行，请用 `npm start`（前台）或自行托管 `agents-hud serve`。");
    return 1;
  }
  return r.status ?? 0;
}

function help(): void {
  console.log(`AgentsHUD —— Claude Code 状态面板服务

用法: agents-hud <命令>

  start      启动后台服务（brew services，开机自启）
  stop       停止后台服务
  restart    重启后台服务
  status     查看服务状态
  connect    显示配对二维码与连接信息（手机 App 扫码）
  serve      在前台运行服务（默认；launchd 调用此项）
  help       显示本帮助

无参数时等同于 serve。`);
}

const cmd = (process.argv[2] ?? "").toLowerCase();
switch (cmd) {
  case "":
  case "serve":
  case "run":
    serve().catch((err) => {
      console.error("Fatal:", err);
      process.exit(1);
    });
    break;
  case "connect":
  case "qr":
    connect();
    break;
  case "start":
  case "stop":
  case "restart":
    process.exit(brewService(cmd));
    break;
  case "status":
    process.exit(brewService("info"));
    break;
  case "help":
  case "-h":
  case "--help":
    help();
    break;
  default:
    console.error(`未知命令: ${cmd}\n`);
    help();
    process.exit(1);
}
