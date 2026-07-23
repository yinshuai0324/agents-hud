#pragma once

#include "net.h"

void uiBegin();
// Redraws changed fields only (text padding erases remnants — no sprites, the
// ESP8266 heap can't afford full-region buffers next to WiFi + TLS).
void uiUpdate(NetState state, const Snapshot &snap, bool haveData);
