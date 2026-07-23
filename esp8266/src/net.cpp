#include "net.h"

#include <ArduinoJson.h>
#include <ESP8266WiFi.h>
#include <ESP8266mDNS.h>
#include <WebSocketsClient.h>

// Data considered stale when nothing arrives for this long (server pushes
// every 3s; short reconnects stay under it).
static const uint32_t STALE_MS = 30000;
// WS down this long (WiFi up) -> mDNS rediscovery of a moved server.
static const uint32_t REDISCOVER_MS = 30000;
// Provisioning feedback: how long we keep reporting bad_pass etc. before
// falling back to a plain retry loop.
static const uint32_t WIFI_TIMEOUT_MS = 20000;

static ProvConfig s_cfg;
static bool s_haveCfg = false;
static char s_deviceId[8] = "";
static WebSocketsClient s_ws;
static bool s_wsStarted = false;
static bool s_wsConnected = false;
static uint32_t s_lastDataMs = 0;
static uint32_t s_wsDownSinceMs = 0;
static uint32_t s_wifiAttemptMs = 0;
static bool s_reportedWsOk = false;
static Snapshot s_snap;
static bool s_haveData = false;

const char *netDeviceId() { return s_deviceId; }
NetState s_state = NET_PROVISIONING;
NetState netState() { return s_state; }
const Snapshot &netSnapshot() { return s_snap; }
bool netHaveData() { return s_haveData; }

// ---------------------------------------------------------------- payload

static bool parseSnap(const char *body) {
    // ~300B payload; 768 leaves headroom for long model/plan strings.
    StaticJsonDocument<768> doc;
    if (deserializeJson(doc, body) != DeserializationError::Ok) return false;
    const char *t = doc["t"] | "";
    if (t[0] != '\0' && strcmp(t, "snap") != 0) return false; // hi/anim/... ignored
    memset(&s_snap, 0, sizeof(s_snap));
    s_snap.u5hPercent = doc["p5"] | 0;
    s_snap.u5hResetMin = doc["r5"] | 0;
    s_snap.u7dPercent = doc.containsKey("p7") ? (int)(doc["p7"] | 0) : -1;
    s_snap.u7dResetMin = doc["r7"] | 0;
    s_snap.todayTokens = doc["tt"] | 0LL;
    s_snap.u5hBurnPerMin = doc["bu"] | 0LL;
    s_snap.u5hLive = (doc["lv"] | 0) != 0;
    s_snap.sWorking = doc["w"] | 0;
    s_snap.sNotify = doc["n"] | 0;
    s_snap.sWaiting = doc["wa"] | 0;
    s_snap.sError = doc["e"] | 0;
    s_snap.sQuiet = doc["q"] | 0;
    s_snap.sTotal = doc["to"] | 0;
    strlcpy(s_snap.model, doc["m"] | "", sizeof(s_snap.model));
    strlcpy(s_snap.plan, doc["pl"] | "", sizeof(s_snap.plan));
    strlcpy(s_snap.host, doc["h"] | "", sizeof(s_snap.host));
    strlcpy(s_snap.dominant, doc["d"] | "", sizeof(s_snap.dominant));
    return true;
}

// -------------------------------------------------------------- websocket

static bool splitUrl(const char *url, char *host, size_t hostCap, uint16_t *port) {
    // Accepts "ws://host:port" (no path). Port defaults to 4317.
    const char *p = url;
    if (strncmp(p, "ws://", 5) == 0) p += 5;
    const char *colon = strchr(p, ':');
    if (colon) {
        size_t n = (size_t)(colon - p);
        if (n >= hostCap) return false;
        memcpy(host, p, n);
        host[n] = '\0';
        *port = (uint16_t)atoi(colon + 1);
    } else {
        strlcpy(host, p, hostCap);
        *port = 4317;
    }
    return host[0] != '\0' && *port != 0;
}

static void wsEvent(WStype_t type, uint8_t *payload, size_t length) {
    switch (type) {
    case WStype_CONNECTED: {
        s_wsConnected = true;
        s_wsDownSinceMs = 0;
        char hello[160];
        snprintf(hello, sizeof(hello),
                 "{\"t\":\"hello\",\"proto\":1,\"id\":\"%s\",\"board\":\"%s\",\"fw\":\"%s\"}",
                 s_deviceId, AHUD_BOARD_ID, AHUD_FW_VERSION);
        s_ws.sendTXT(hello);
        break;
    }
    case WStype_DISCONNECTED:
        if (s_wsConnected || s_wsDownSinceMs == 0) s_wsDownSinceMs = millis();
        s_wsConnected = false;
        break;
    case WStype_TEXT:
        if (payload && parseSnap((const char *)payload)) {
            s_lastDataMs = millis();
            s_haveData = true;
            if (!s_reportedWsOk) {
                provEmitStatus("ws_ok", WiFi.localIP().toString().c_str());
                s_reportedWsOk = true;
            }
        }
        break;
    default:
        break;
    }
}

static void wsStart() {
    char host[96];
    uint16_t port = 0;
    if (!splitUrl(s_cfg.url, host, sizeof(host), &port)) return;
    char path[256];
    snprintf(path, sizeof(path), "/device?token=%s&id=%s&board=%s&fw=%s",
             s_cfg.token, s_deviceId, AHUD_BOARD_ID, AHUD_FW_VERSION);
    if (s_wsStarted) s_ws.disconnect();
    s_ws.begin(host, port, path);
    s_ws.onEvent(wsEvent);
    s_ws.setReconnectInterval(5000);
    // Protocol-level ping every 10s; treat 2 missed pongs as dead.
    s_ws.enableHeartbeat(10000, 3000, 2);
    s_wsStarted = true;
    s_wsDownSinceMs = millis();
}

// ------------------------------------------------------------------ mDNS

static void mdnsRediscover() {
    // The Mac's IP changed: find _agentshud._tcp again. The ESP8266 mDNS
    // library exposes no TXT records on query results, so we take the first
    // responder (fine for a single-Mac network).
    int n = MDNS.queryService("agentshud", "tcp");
    if (n <= 0) return;
    char url[128];
    snprintf(url, sizeof(url), "ws://%s:%u", MDNS.IP(0).toString().c_str(), MDNS.port(0));
    if (strcmp(url, s_cfg.url) != 0) {
        strlcpy(s_cfg.url, url, sizeof(s_cfg.url));
        provSave(s_cfg);
        wsStart();
    }
}

// ------------------------------------------------------------------ wifi

static void wifiBegin() {
    WiFi.mode(WIFI_STA);
    WiFi.persistent(false); // our LittleFS config is the single source of truth
    WiFi.hostname((String("agentshud-") + s_deviceId).c_str());
    WiFi.begin(s_cfg.ssid, s_cfg.pw);
    s_wifiAttemptMs = millis();
}

void netApplyConfig(const ProvConfig &cfg) {
    s_cfg = cfg;
    s_haveCfg = true;
    s_reportedWsOk = false;
    s_haveData = false;
    if (s_wsStarted) {
        s_ws.disconnect();
        s_wsStarted = false;
    }
    WiFi.disconnect();
    wifiBegin();
}

void netBegin() {
    uint8_t mac[6];
    WiFi.macAddress(mac);
    snprintf(s_deviceId, sizeof(s_deviceId), "%02X%02X", mac[4], mac[5]);

    s_haveCfg = provLoad(s_cfg);
    if (s_haveCfg) {
        wifiBegin();
        s_state = NET_WIFI_CONNECTING;
    } else {
        s_state = NET_PROVISIONING;
    }
}

void netLoop() {
    static bool wasConnected = false;
    static uint32_t lastStatusEmit = 0;
    uint32_t now = millis();

    if (s_wsStarted) s_ws.loop();
    if (wasConnected) MDNS.update();

    if (!s_haveCfg) {
        s_state = NET_PROVISIONING;
        return;
    }

    wl_status_t st = WiFi.status();
    if (st == WL_CONNECTED && !wasConnected) {
        wasConnected = true;
        provEmitStatus("got_ip", WiFi.localIP().toString().c_str());
        MDNS.begin((String("agentshud-") + s_deviceId).c_str());
        wsStart();
    } else if (st != WL_CONNECTED && wasConnected) {
        wasConnected = false;
        s_wsConnected = false;
        s_wifiAttemptMs = now;
    }

    if (st != WL_CONNECTED) {
        s_state = NET_WIFI_CONNECTING;
        // Provisioning feedback for the Mac (throttled to 1 line / 2s).
        if (now - lastStatusEmit > 2000) {
            lastStatusEmit = now;
            // ESP8266 core has no WL_WRONG_PASSWORD enum (that's ESP32); a wrong
            // passphrase surfaces here as WL_CONNECT_FAILED.
            if (st == WL_NO_SSID_AVAIL) provEmitStatus("ap_not_found", nullptr);
            else if (st == WL_CONNECT_FAILED) provEmitStatus("bad_pass", nullptr);
            else provEmitStatus("connecting", nullptr);
        }
        // The core auto-retries; kick it if it has been idle for too long.
        if (now - s_wifiAttemptMs > WIFI_TIMEOUT_MS) {
            WiFi.disconnect();
            wifiBegin();
        }
        return;
    }

    // WiFi up.
    if (!s_wsConnected) {
        s_state = NET_SERVER_UNREACHABLE;
        if (s_wsDownSinceMs != 0 && now - s_wsDownSinceMs > REDISCOVER_MS) {
            s_wsDownSinceMs = now; // rate-limit queries
            mdnsRediscover();
        }
        return;
    }
    s_state = (now - s_lastDataMs > STALE_MS) ? NET_SERVER_UNREACHABLE : NET_OK;
}
