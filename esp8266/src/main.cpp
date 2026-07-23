// AgentsHUD firmware for the SmallDesktopDisplay board (ESP8266 + 1.54" TFT).
// Provisioned over USB serial from the Mac app (no Bluetooth on ESP8266),
// then streams compact snapshots from the server's /device WebSocket.
#include <Arduino.h>
#include <LittleFS.h>

#include "net.h"
#include "prov.h"
#include "ui.h"

void setup() {
    Serial.begin(115200);
    LittleFS.begin();
    uiBegin();
    netBegin();
}

void loop() {
    provSerialPoll();
    netLoop();

    static uint32_t lastDraw = 0;
    static bool prevText = false;
    if (millis() - lastDraw >= 250) {
        lastDraw = millis();
        if (netTextActive()) {
            uiShowText(netTextTitle(), netTextBody());
            prevText = true;
        } else {
            if (prevText) uiEnterUsage(); // returning from a text card
            prevText = false;
            uiUpdate(netState(), netSnapshot(), netHaveData());
        }
    }
    delay(2);
}
