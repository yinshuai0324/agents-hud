#include "prov.h"

#include <ArduinoJson.h>
#include <LittleFS.h>

#include "net.h"

static const char *CFG_PATH = "/cfg.json";

bool provLoad(ProvConfig &out) {
    memset(&out, 0, sizeof(out));
    File f = LittleFS.open(CFG_PATH, "r");
    if (!f) return false;
    StaticJsonDocument<512> doc;
    DeserializationError err = deserializeJson(doc, f);
    f.close();
    if (err) return false;
    strlcpy(out.ssid, doc["ssid"] | "", sizeof(out.ssid));
    strlcpy(out.pw, doc["pw"] | "", sizeof(out.pw));
    strlcpy(out.url, doc["url"] | "", sizeof(out.url));
    strlcpy(out.token, doc["token"] | "", sizeof(out.token));
    strlcpy(out.name, doc["name"] | "", sizeof(out.name));
    return out.ssid[0] != '\0' && out.url[0] != '\0';
}

bool provSave(const ProvConfig &cfg) {
    StaticJsonDocument<512> doc;
    doc["ssid"] = cfg.ssid;
    doc["pw"] = cfg.pw;
    doc["url"] = cfg.url;
    doc["token"] = cfg.token;
    doc["name"] = cfg.name;
    File f = LittleFS.open(CFG_PATH, "w");
    if (!f) return false;
    serializeJson(doc, f);
    f.close();
    return true;
}

void provErase() {
    LittleFS.remove(CFG_PATH);
}

void provEmitStatus(const char *st, const char *ip) {
    StaticJsonDocument<128> doc;
    doc["t"] = "st";
    doc["st"] = st;
    doc["ip"] = ip ? ip : "";
    serializeJson(doc, Serial);
    Serial.println();
}

static void emitInfo() {
    StaticJsonDocument<128> doc;
    doc["t"] = "info";
    doc["board"] = AHUD_BOARD_ID;
    doc["fw"] = AHUD_FW_VERSION;
    doc["id"] = netDeviceId();
    serializeJson(doc, Serial);
    Serial.println();
}

static void handleLine(const char *line) {
    // Single-char console commands (parity with the esp32 firmware).
    if (line[1] == '\0') {
        if (line[0] == 'r') { ESP.restart(); }
        if (line[0] == 'p') { provErase(); ESP.restart(); }
        return;
    }
    StaticJsonDocument<512> doc;
    if (deserializeJson(doc, line) != DeserializationError::Ok) return;
    const char *t = doc["t"] | "";
    if (strcmp(t, "info?") == 0) {
        emitInfo();
    } else if (strcmp(t, "prov") == 0) {
        ProvConfig cfg;
        memset(&cfg, 0, sizeof(cfg));
        strlcpy(cfg.ssid, doc["ssid"] | "", sizeof(cfg.ssid));
        strlcpy(cfg.pw, doc["pw"] | "", sizeof(cfg.pw));
        strlcpy(cfg.url, doc["url"] | "", sizeof(cfg.url));
        strlcpy(cfg.token, doc["token"] | "", sizeof(cfg.token));
        strlcpy(cfg.name, doc["name"] | "", sizeof(cfg.name));
        if (cfg.ssid[0] == '\0' || cfg.url[0] == '\0') {
            provEmitStatus("bad_request", nullptr);
            return;
        }
        provSave(cfg);
        provEmitStatus("connecting", nullptr);
        netApplyConfig(cfg); // (re)start WiFi with the new credentials
    } else if (strcmp(t, "reset") == 0) {
        provErase();
        provEmitStatus("idle", nullptr);
        delay(100);
        ESP.restart();
    }
}

void provSerialPoll() {
    static char buf[600];
    static size_t len = 0;
    while (Serial.available() > 0) {
        char c = (char)Serial.read();
        if (c == '\n' || c == '\r') {
            if (len > 0) {
                buf[len] = '\0';
                handleLine(buf);
                len = 0;
            }
        } else if (len < sizeof(buf) - 1) {
            buf[len++] = c;
        } else {
            len = 0; // overlong garbage — drop the line
        }
    }
}
