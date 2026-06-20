import os from "node:os";
import qrcode from "qrcode-terminal";

/** Pick the most likely LAN IPv4 address (private ranges, non-internal). */
export function lanIp(): string {
  const ifaces = os.networkInterfaces();
  const candidates: { addr: string; rank: number }[] = [];
  for (const [name, addrs] of Object.entries(ifaces)) {
    for (const a of addrs ?? []) {
      if (a.family !== "IPv4" || a.internal) continue;
      // Prefer common LAN ranges and Wi-Fi/Ethernet interfaces.
      let rank = 0;
      if (a.address.startsWith("192.168.")) rank = 3;
      else if (a.address.startsWith("10.")) rank = 2;
      else if (a.address.startsWith("172.")) rank = 1;
      if (/^en0$|wlan0|eth0|en1/.test(name)) rank += 1;
      candidates.push({ addr: a.address, rank });
    }
  }
  candidates.sort((a, b) => b.rank - a.rank);
  return candidates[0]?.addr ?? "127.0.0.1";
}

export interface PairingPayload {
  v: 1;
  url: string; // ws://ip:port
  token: string; // shared secret, "" if disabled
  name: string; // friendly host name shown in the app
}

export function buildPairing(port: number, token: string): PairingPayload {
  return {
    v: 1,
    url: `ws://${lanIp()}:${port}`,
    token,
    name: os.hostname().replace(/\.local$/, ""),
  };
}

/** Print the pairing QR code plus a human-readable summary to the terminal. */
export function printPairingQr(payload: PairingPayload): void {
  const data = JSON.stringify(payload);
  console.log("\n  📡  CC 信号塔 — 用手机 App 扫码连接 / Scan with the app:\n");
  qrcode.generate(data, { small: true }, (qr) => {
    console.log(
      qr
        .split("\n")
        .map((l) => "   " + l)
        .join("\n"),
    );
  });
  console.log(`\n   WebSocket : ${payload.url}`);
  console.log(`   Host      : ${payload.name}`);
  console.log(`   Auth      : ${payload.token ? "on (token set)" : "off"}`);
  console.log("");
}
