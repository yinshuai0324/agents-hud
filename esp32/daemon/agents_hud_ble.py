#!/usr/bin/env python3
"""AgentsHUD BLE daemon.

Polls the local AgentsHUD server (http://127.0.0.1:4317/api/snapshot) and
pushes a compact JSON payload to the ESP32 AMOLED dial over BLE GATT.
The dial advertises as "AgentsHUD" with the service UUID below; the daemon
auto-reconnects whenever the dial or the server goes away.
"""

import asyncio
import json
import os
import sys
import time
import urllib.request

from bleak import BleakClient, BleakScanner

SERVICE_UUID = "41485544-6469-616c-2d64-617461000001"
RX_CHAR_UUID = "41485544-6469-616c-2d64-617461000002"
SNAPSHOT_URL = f"http://127.0.0.1:{os.environ.get('CC_SIGNAL_PORT', '4317')}/api/snapshot"
INTERVAL_S = 3.0


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
    }
    if isinstance(u7, dict):
        payload["p7"] = u7.get("percent", 0)
        payload["r7"] = u7.get("resetInMinutes", 0)
    return json.dumps(payload, separators=(",", ":")).encode()


def is_dial(device, ad) -> bool:
    uuids = [u.lower() for u in (ad.service_uuids or [])]
    return SERVICE_UUID in uuids or (device.name or "") == "AgentsHUD"


async def run_connection() -> None:
    dev = await BleakScanner.find_device_by_filter(is_dial, timeout=15)
    if dev is None:
        log("dial not found (is it powered on?)")
        return
    log(f"connecting to {dev.name or dev.address}")
    async with BleakClient(dev) as client:
        log("connected, streaming snapshots")
        while client.is_connected:
            started = time.monotonic()
            try:
                data = fetch_compact()
            except Exception as e:
                log(f"snapshot fetch failed: {e}")
                await asyncio.sleep(INTERVAL_S)
                continue
            await client.write_gatt_char(RX_CHAR_UUID, data, response=True)
            elapsed = time.monotonic() - started
            await asyncio.sleep(max(0.5, INTERVAL_S - elapsed))
    log("disconnected")


async def main() -> None:
    log("AgentsHUD BLE daemon starting")
    while True:
        try:
            await run_connection()
        except Exception as e:
            log(f"ble error: {e}")
        await asyncio.sleep(3)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
