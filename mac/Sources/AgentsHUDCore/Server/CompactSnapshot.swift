import Foundation

/// Builds the compact JSON pushed to ESP32 dials over the /device WebSocket.
/// Field set and truncation mirror the retired BLE daemon's fetch_compact()
/// (esp32/daemon/agents_hud_ble.py) so the firmware's parse_payload() keeps
/// working unchanged. The only addition is `"t":"snap"` for message routing.
public enum CompactSnapshot {
    public static func json(from snap: Snapshot, hostName: String) -> String {
        var obj: [(String, Any)] = [
            ("t", "snap"),
            ("p5", snap.usage5h.percent),
            ("r5", snap.usage5h.resetInMinutes),
            ("tt", snap.today.tokens),
            ("bu", snap.usage5h.burnRatePerMin),
            // Both Claude statusLine values (live) and Codex transcript values
            // (local) are exact provider-reported quotas.
            ("lv", snap.usage5h.source == "estimate" ? 0 : 1),
            ("w", snap.status.working),
            ("n", snap.status.notify),
            ("wa", snap.status.waiting),
            ("e", snap.status.error),
            ("q", snap.status.quiet),
            ("to", snap.status.total),
            ("d", snap.status.dominant.rawValue),
            ("m", String(snap.model.prefix(24))),
            ("pl", String(snap.plan.prefix(24))),
            ("pr", String(snap.provider.prefix(12))),
            ("h", String(hostName.prefix(23))),
        ]
        if let u7 = snap.usage7d {
            obj.append(("p7", u7.percent))
            obj.append(("r7", u7.resetInMinutes))
        }
        return encodeOrdered(obj)
    }

    /// Minimal single-line JSON encoder for flat (String, scalar) pairs.
    /// Deterministic key order keeps device-side debugging simple.
    public static func encodeOrdered(_ pairs: [(String, Any)]) -> String {
        var out = "{"
        for (i, (k, v)) in pairs.enumerated() {
            if i > 0 { out += "," }
            out += "\"\(k)\":"
            switch v {
            case let s as String:
                out += encodeJSONString(s)
            case let n as Int:
                out += String(n)
            case let d as Double:
                out += d.rounded() == d ? String(Int(d)) : String(d)
            case let b as Bool:
                out += b ? "true" : "false"
            default:
                out += "null"
            }
        }
        return out + "}"
    }

    static func encodeJSONString(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 {
                    out += String(format: "\\u%04x", c.value)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out + "\""
    }
}
