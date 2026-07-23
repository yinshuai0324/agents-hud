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
    if (millis() - lastDraw >= 250) {
        lastDraw = millis();
        uiUpdate(netState(), netSnapshot(), netHaveData());
    }
    delay(2);
}
