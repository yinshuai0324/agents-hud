#!/usr/bin/env python3
"""AgentsHUD BLE daemon.

Polls the local AgentsHUD server (http://127.0.0.1:4317/api/snapshot) and
pushes a compact JSON payload to every ESP32 AMOLED dial in range over BLE
GATT. Dials advertise as "AgentsHUD-XXXX" (XXXX = per-device MAC suffix)
with the service UUID below; the daemon keeps one connection per dial and
auto-reconnects whenever a dial or the server goes away.

Env:
  AGENTS_HUD_BLE_ONLY  optional comma list; only connect to dials whose
                       name or address contains one of these substrings,
                       e.g. "F232" or "AgentsHUD-F232,AgentsHUD-A01C".
  CC_SIGNAL_PORT       AgentsHUD server port (default 4317).
"""

import asyncio
import json
import os
import platform
import sys
import time
import urllib.request

from bleak import BleakClient, BleakScanner

SERVICE_UUID = "41485544-6469-616c-2d64-617461000001"
RX_CHAR_UUID = "41485544-6469-616c-2d64-617461000002"
SNAPSHOT_URL = f"http://127.0.0.1:{os.environ.get('CC_SIGNAL_PORT', '4317')}/api/snapshot"
INTERVAL_S = 3.0
SCAN_EVERY_S = 8.0
# The dial can reject a host (switch/lock buttons). A rejected connection is
# torn down within seconds — back off so we don't hammer it.
REJECT_COOLDOWN_S = 60.0
HOSTNAME = platform.node().split(".")[0][:23] or "mac"

ONLY = [s.strip().lower() for s in os.environ.get("AGENTS_HUD_BLE_ONLY", "").split(",") if s.strip()]


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def fetch_compact() -> bytes:
    with urllib.request.urlopen(SNAPSHOT_URL, timeout=3) as r:
        snap = json.load(r)
    u5 = snap.get("usage5h") or {}
    u7 = snap.get("usage7d")
    st = snap.get("status") or {}
    totals = snap.get("totals") or {}
    today = totals.get("todayTokens") or (snap.get("today") or {}).get("tokens", 0)
    payload = {
        "p5": u5.get("percent", 0),
        "r5": u5.get("resetInMinutes", 0),
        "tt": today,
        "bu": u5.get("burnRatePerMin", 0),
        "lv": 1 if u5.get("source") == "live" else 0,
        "w": st.get("working", 0),
        "n": st.get("notify", 0),
        "wa": st.get("waiting", 0),
        "e": st.get("error", 0),
        "q": st.get("quiet", 0),
        "to": st.get("total", 0),
        "m": (snap.get("model") or "")[:24],
        "pl": (snap.get("plan") or "")[:24],
        "h": HOSTNAME,
    }
    if isinstance(u7, dict):
        payload["p7"] = u7.get("percent", 0)
        payload["r7"] = u7.get("resetInMinutes", 0)
    return json.dumps(payload, separators=(",", ":")).encode()


def is_dial(device, ad) -> bool:
    uuids = [u.lower() for u in (ad.service_uuids or [])]
    named = (device.name or "").startswith("AgentsHUD")
    if not (SERVICE_UUID in uuids or named):
        return False
    if ONLY:
        ident = f"{device.name or ''} {device.address}".lower()
        return any(want in ident for want in ONLY)
    return True


async def serve_dial(device, connected: set, cooldown: dict) -> None:
    label = f"{device.name or 'AgentsHUD'} [{device.address}]"
    started_at = time.monotonic()
    try:
        async with BleakClient(device) as client:
            log(f"connected: {label}")
            while client.is_connected:
                started = time.monotonic()
                try:
                    data = fetch_compact()
                except Exception as e:
                    log(f"snapshot fetch failed: {e}")
                    await asyncio.sleep(INTERVAL_S)
                    continue
                await client.write_gatt_char(RX_CHAR_UUID, data, response=True)
                await asyncio.sleep(max(0.5, INTERVAL_S - (time.monotonic() - started)))
    except Exception as e:
        log(f"{label}: {e}")
    finally:
        connected.discard(device.address)
        if time.monotonic() - started_at < 10:
            cooldown[device.address] = time.monotonic() + REJECT_COOLDOWN_S
            log(f"disconnected fast (rejected by dial?): {label} — cooling down {int(REJECT_COOLDOWN_S)}s")
        else:
            log(f"disconnected: {label}")


async def main() -> None:
    log(f"AgentsHUD BLE daemon starting as \"{HOSTNAME}\"" + (f" (filter: {','.join(ONLY)})" if ONLY else ""))
    connected: set = set()
    cooldown: dict = {}
    while True:
        try:
            found = await BleakScanner.discover(timeout=5, return_adv=True)
            now = time.monotonic()
            for device, ad in found.values():
                if device.address in connected or cooldown.get(device.address, 0) > now:
                    continue
                if is_dial(device, ad):
                    connected.add(device.address)
                    asyncio.create_task(serve_dial(device, connected, cooldown))
        except Exception as e:
            log(f"scan error: {e}")
        await asyncio.sleep(SCAN_EVERY_S)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
