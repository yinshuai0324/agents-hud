import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

/**
 * BLE dial pusher: a Python (bleak) child process that streams /api/snapshot
 * to the ESP32 AMOLED dial over Bluetooth LE. Managed by the server so brew
 * services supervises a single process. Toggled via `agents-hud ble on|off`.
 */

/** Marker file: presence = BLE push enabled. */
export function bleMarkerPath(): string {
  return path.join(os.homedir(), ".claude", "agents-hud-ble.on");
}

/** Target file: dial ID(s) to connect to; absent/"all" = every dial. */
export function bleTargetPath(): string {
  return path.join(os.homedir(), ".claude", "agents-hud-ble.target");
}

export function bleTarget(): string {
  try {
    return fs.readFileSync(bleTargetPath(), "utf8").trim() || "all";
  } catch {
    return "all";
  }
}

/** Set the connect target ("all" clears). Picked up by the daemon within seconds. */
export function bleSetTarget(target: string): void {
  const t = target.trim();
  if (!t || t.toLowerCase() === "all") {
    fs.rmSync(bleTargetPath(), { force: true });
  } else {
    fs.mkdirSync(path.dirname(bleTargetPath()), { recursive: true });
    fs.writeFileSync(bleTargetPath(), t);
  }
}

/** Scan for dials (blocking, ~8s) and print them. */
export function bleScan(): number {
  const paths = daemonPaths();
  if (!paths) {
    console.error("BLE 运行环境缺失（重装 agents-hud？）");
    return 1;
  }
  console.log("正在扫描附近的屏幕（约 8 秒）…");
  const r = spawnSync(paths.py, [paths.script, "--scan"], { stdio: "inherit" });
  return r.status ?? 1;
}

export function bleEnabled(): boolean {
  return fs.existsSync(bleMarkerPath());
}

export function bleSetEnabled(on: boolean): void {
  const marker = bleMarkerPath();
  if (on) {
    fs.mkdirSync(path.dirname(marker), { recursive: true });
    fs.writeFileSync(marker, "");
  } else {
    fs.rmSync(marker, { force: true });
  }
}

function repoRoot(): string {
  // dist/ble.js -> server/dist -> server -> repo root (dev fallback only)
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
}

/** Python interpreter + daemon script. Brew wrapper sets the env vars. */
function daemonPaths(): { py: string; script: string } | null {
  const py =
    process.env.AGENTS_HUD_BLE_PY ||
    path.join(repoRoot(), "esp32", "daemon", ".venv", "bin", "python");
  const script =
    process.env.AGENTS_HUD_BLE_SCRIPT ||
    path.join(repoRoot(), "esp32", "daemon", "agents_hud_ble.py");
  if (!fs.existsSync(py) || !fs.existsSync(script)) return null;
  return { py, script };
}

let child: ChildProcess | null = null;
let stopping = false;

export function bleStart(): void {
  if (!bleEnabled()) return;
  const paths = daemonPaths();
  if (!paths) {
    console.log("   BLE: daemon runtime not found (reinstall agents-hud?) — skipped");
    return;
  }

  const respawn = () => {
    if (stopping) return;
    child = spawn(paths.py, [paths.script], { stdio: ["ignore", "pipe", "pipe"] });
    console.log(`   BLE: pusher started (pid ${child.pid})`);
    child.stdout?.on("data", (d) => process.stdout.write(`   BLE: ${d}`));
    child.stderr?.on("data", (d) => process.stderr.write(`   BLE! ${d}`));
    child.on("exit", (code) => {
      child = null;
      if (stopping) return;
      console.log(`   BLE: pusher exited (${code}), restarting in 5s`);
      setTimeout(respawn, 5000).unref();
    });
  };
  respawn();
}

export function bleStop(): void {
  stopping = true;
  if (child) {
    child.kill("SIGTERM");
    child = null;
  }
}
