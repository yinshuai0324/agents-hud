#include "ui.h"

#include <TFT_eSPI.h>

// Anthropic-ish palette in RGB565 (matches the esp32 dial's scheme).
#define COL_BG      0x0000
#define COL_PANEL   0x18E3
#define COL_TEXT    0xFFDF
#define COL_DIM     0xB596
#define COL_ACCENT  0xDBAA  // #d97757
#define COL_BAR_BG  0x2124
// Status colors: working yellow / waiting blue / notify orange / error red /
// quiet green (keep in sync with the Mac & Android palettes).
#define COL_WORK    0xFE60
#define COL_WAIT    0x34DF
#define COL_NOTIFY  0xFC80
#define COL_ERROR   0xF1A7
#define COL_QUIET   0x2E4B

static TFT_eSPI tft;

static uint16_t dominantColor(const char *d) {
    if (strcmp(d, "error") == 0) return COL_ERROR;
    if (strcmp(d, "notify") == 0) return COL_NOTIFY;
    if (strcmp(d, "waiting") == 0) return COL_WAIT;
    if (strcmp(d, "working") == 0) return COL_WORK;
    return COL_QUIET;
}

static void fmtTokens(long long v, char *out, size_t cap) {
    if (v >= 1000000) snprintf(out, cap, "%.1fM", v / 1000000.0);
    else if (v >= 1000) snprintf(out, cap, "%.1fk", v / 1000.0);
    else snprintf(out, cap, "%lld", v);
}

static void fmtReset(int minutes, char *out, size_t cap) {
    if (minutes <= 0) { strlcpy(out, "--", cap); return; }
    if (minutes >= 60) snprintf(out, cap, "%dh%02dm", minutes / 60, minutes % 60);
    else snprintf(out, cap, "%dm", minutes);
}

// Set true when a full-screen takeover (text card) wiped the usage chrome, so
// the next uiShowText/uiEnterUsage forces a full redraw.
static bool s_forceText = false;

static void drawUsageChrome() {
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setTextDatum(TL_DATUM);
    tft.drawString("AgentsHUD", 52, 8, 2);
    tft.drawString("5H", 12, 40, 4);
    tft.drawString("7D", 12, 138, 4);
    tft.drawFastHLine(0, 30, 240, COL_PANEL);
    tft.drawFastHLine(0, 130, 240, COL_PANEL);
    tft.drawFastHLine(0, 168, 240, COL_PANEL);
    tft.drawFastHLine(0, 206, 240, COL_PANEL);
}

void uiBegin() {
    tft.init();
    pinMode(TFT_BL, OUTPUT);
    digitalWrite(TFT_BL, TFT_BACKLIGHT_ON);
    tft.setRotation(0);
    tft.fillScreen(COL_BG);
    drawUsageChrome();
}

void uiSetDisplayPower(bool on) {
    digitalWrite(TFT_BL, on ? TFT_BACKLIGHT_ON : (TFT_BACKLIGHT_ON == HIGH ? LOW : HIGH));
}

// Redraw the usage page background/chrome (call when returning from a text card).
void uiEnterUsage() {
    tft.fillScreen(COL_BG);
    drawUsageChrome();
    s_forceText = true; // next text entry must redraw over usage
}

// Progress bar with rounded-ish ends, erases stale fill.
static void drawBar(int x, int y, int w, int h, int percent, uint16_t color) {
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    int fill = (w - 2) * percent / 100;
    tft.drawRect(x, y, w, h, COL_BAR_BG);
    tft.fillRect(x + 1, y + 1, fill, h - 2, color);
    tft.fillRect(x + 1 + fill, y + 1, (w - 2) - fill, h - 2, COL_PANEL);
}

// Word-wrapped full-screen text card. Redraws whole screen (called only on
// change from main), so no padding tricks needed.
void uiShowText(const char *title, const char *body) {
    static char lastTitle[64] = "\x01";
    static char lastBody[256] = "\x01";
    if (!s_forceText && strcmp(title, lastTitle) == 0 && strcmp(body, lastBody) == 0) return;
    s_forceText = false;
    strlcpy(lastTitle, title, sizeof(lastTitle));
    strlcpy(lastBody, body, sizeof(lastBody));

    tft.fillScreen(COL_BG);
    tft.drawRect(0, 0, 240, 240, COL_ACCENT);
    tft.drawRect(1, 1, 238, 238, COL_ACCENT);

    tft.setTextDatum(TC_DATUM);
    if (title[0]) {
        tft.setTextColor(COL_ACCENT, COL_BG);
        tft.drawString(title, 120, 18, 4);
    }

    // Greedy word wrap in font 4 (~14px wide glyphs -> ~15 chars/line at 216px).
    tft.setTextColor(COL_TEXT, COL_BG);
    tft.setTextDatum(TL_DATUM);
    const int maxCharsPerLine = 15;
    int y = title[0] ? 64 : 40;
    char line[32] = "";
    int lineLen = 0;
    const char *p = body;
    while (*p && y < 220) {
        // grab next token (word) up to space
        const char *sp = strchr(p, ' ');
        int wordLen = sp ? (int)(sp - p) : (int)strlen(p);
        if (wordLen > maxCharsPerLine) wordLen = maxCharsPerLine;
        if (lineLen > 0 && lineLen + 1 + wordLen > maxCharsPerLine) {
            tft.drawString(line, 14, y, 4);
            y += 30;
            line[0] = '\0';
            lineLen = 0;
        }
        if (lineLen > 0) { line[lineLen++] = ' '; line[lineLen] = '\0'; }
        strncat(line, p, wordLen);
        lineLen += wordLen;
        p += wordLen;
        while (*p == ' ') p++;
    }
    if (lineLen > 0 && y < 226) tft.drawString(line, 14, y, 4);

    tft.setTextDatum(BC_DATUM);
    tft.setTextColor(COL_DIM, COL_BG);
    tft.drawString(netDeviceId(), 120, 232, 2);
}

void uiUpdate(NetState state, const Snapshot &snap, bool haveData) {
    char buf[48];

    // State border = the dial's "ring".
    uint16_t border = (state == NET_OK && haveData)
        ? dominantColor(snap.dominant) : COL_BAR_BG;
    tft.drawRect(0, 0, 240, 240, border);
    tft.drawRect(1, 1, 238, 238, border);

    // Device id top-right (always useful for provisioning/support).
    tft.setTextDatum(TR_DATUM);
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setTextPadding(70);
    tft.drawString(netDeviceId(), 228, 8, 2);

    // Current provider icon: Claude = A, Codex = >_, Gemini = G.
    const bool codex = strcmp(snap.provider, "codex") == 0;
    const bool gemini = strcmp(snap.provider, "gemini") == 0;
    const uint16_t providerColor = codex ? COL_QUIET : (gemini ? COL_WAIT : COL_ACCENT);
    tft.fillRoundRect(12, 8, 32, 22, 6, providerColor);
    tft.setTextDatum(MC_DATUM);
    tft.setTextColor(COL_BG, providerColor);
    tft.setTextPadding(28);
    tft.drawString(codex ? ">_" : (gemini ? "G" : (snap.provider[0] ? "A" : "?")), 28, 19, 2);

    // Connection banner replaces the status row when not OK.
    tft.setTextDatum(TL_DATUM);
    tft.setTextPadding(216);
    switch (state) {
    case NET_PROVISIONING:
        tft.setTextColor(COL_ACCENT, COL_BG);
        tft.drawString("USB pairing: open Mac app", 12, 178, 2);
        break;
    case NET_WIFI_CONNECTING:
        tft.setTextColor(COL_ACCENT, COL_BG);
        tft.drawString("Connecting WiFi...", 12, 178, 2);
        break;
    case NET_SERVER_UNREACHABLE:
        tft.setTextColor(COL_ERROR, COL_BG);
        tft.drawString("Server unreachable", 12, 178, 2);
        break;
    case NET_OK: {
        uint16_t c = dominantColor(snap.dominant);
        tft.fillCircle(18, 186, 5, c);
        tft.setTextColor(COL_TEXT, COL_BG);
        tft.setTextPadding(200);
        if (snap.sWorking > 0) snprintf(buf, sizeof(buf), "working x%d", snap.sWorking);
        else if (snap.sNotify > 0) snprintf(buf, sizeof(buf), "needs approval x%d", snap.sNotify);
        else if (snap.sWaiting > 0) snprintf(buf, sizeof(buf), "your turn x%d", snap.sWaiting);
        else snprintf(buf, sizeof(buf), "idle (%d sessions)", snap.sTotal);
        tft.drawString(buf, 32, 178, 2);
        break;
    }
    }

    if (!haveData) return;

    // 5H block: big percent + live/est marker + reset countdown + bar.
    tft.setTextDatum(TR_DATUM);
    tft.setTextColor(COL_TEXT, COL_BG);
    tft.setTextPadding(130);
    snprintf(buf, sizeof(buf), "%d%%", snap.u5hPercent);
    tft.drawString(buf, 225, 38, 6);

    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setTextPadding(90);
    char rst[16];
    fmtReset(snap.u5hResetMin, rst, sizeof(rst));
    snprintf(buf, sizeof(buf), "%s %s", snap.u5hLive ? "live" : "est", rst);
    tft.drawString(buf, 12, 70, 2);

    drawBar(12, 96, 216, 12, snap.u5hPercent,
            snap.u5hPercent >= 80 ? COL_ERROR : COL_ACCENT);

    // 7D row.
    if (snap.u7dPercent >= 0) {
        drawBar(60, 142, 120, 10, snap.u7dPercent, COL_ACCENT);
        tft.setTextDatum(TR_DATUM);
        tft.setTextColor(COL_TEXT, COL_BG);
        tft.setTextPadding(45);
        snprintf(buf, sizeof(buf), "%d%%", snap.u7dPercent);
        tft.drawString(buf, 228, 138, 2);
    } else {
        tft.fillRect(60, 136, 170, 26, COL_BG);
        tft.setTextDatum(TL_DATUM);
        tft.setTextColor(COL_DIM, COL_BG);
        tft.drawString("--", 60, 138, 2);
    }

    // Footer: model/plan + today tokens + burn rate.
    tft.setTextDatum(TL_DATUM);
    tft.setTextColor(COL_DIM, COL_BG);
    tft.setTextPadding(216);
    snprintf(buf, sizeof(buf), "%s  %s", snap.model, snap.plan);
    tft.drawString(buf, 12, 212, 2);

    char tok[16], burn[16];
    fmtTokens(snap.todayTokens, tok, sizeof(tok));
    fmtTokens(snap.u5hBurnPerMin, burn, sizeof(burn));
    tft.setTextPadding(216);
    snprintf(buf, sizeof(buf), "today %s   %s/min", tok, burn);
    tft.drawString(buf, 12, 226, 1);
}
