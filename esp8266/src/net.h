#pragma once

#include <Arduino.h>

#include "prov.h"

// Parsed subset of the compact /device snapshot (see docs/PROTOCOL.md §3).
// Field-for-field match with the esp32 firmware's ahud_snapshot_t.
struct Snapshot {
    char plan[32];
    char model[40];
    int u5hPercent;
    int u5hResetMin;
    long long u5hBurnPerMin;
    bool u5hLive;
    int u7dPercent; // -1 when the server has no 7d window
    int u7dResetMin;
    long long todayTokens;
    int sWorking;
    int sWaiting;
    int sNotify;
    int sError;
    int sQuiet;
    int sTotal;
    char host[24];
    char dominant[12];
};

enum NetState {
    NET_PROVISIONING,       // no config: waiting for USB serial provisioning
    NET_WIFI_CONNECTING,
    NET_SERVER_UNREACHABLE, // WiFi up but no fresh data
    NET_OK,
};

// Device id, e.g. "315D" (WiFi MAC last two bytes, upper-case hex).
const char *netDeviceId();

void netBegin();
void netLoop();

// Apply freshly provisioned credentials (called from prov.cpp).
void netApplyConfig(const ProvConfig &cfg);

NetState netState();
// Latest snapshot; valid once netHaveData() is true.
const Snapshot &netSnapshot();
bool netHaveData();
