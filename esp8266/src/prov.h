#pragma once

#include <Arduino.h>

// Provisioned connection settings, persisted in LittleFS (/cfg.json).
struct ProvConfig {
    char ssid[33];
    char pw[65];
    char url[128];   // "ws://192.168.1.10:4317"
    char token[65];
    char name[33];   // host name picked at provisioning (mDNS preference)
};

bool provLoad(ProvConfig &out);
bool provSave(const ProvConfig &cfg);
void provErase();

// Serial provisioning protocol (115200, one JSON per line, both directions).
// Mac -> device:
//   {"t":"info?"}                              -> {"t":"info","board":..,"fw":..,"id":..}
//   {"t":"prov","v":1,"ssid":..,"pw":..,"url":..,"token":..,"name":..}
//   {"t":"reset"}    erase provisioning + reboot
// Device -> Mac (also emitted spontaneously while connecting):
//   {"t":"st","st":"connecting|got_ip|ws_ok|bad_pass|ap_not_found|server_fail","ip":".."}
// Plain single-char console commands stay too: r=reboot, p=erase provisioning.
void provSerialPoll();

// Emit a status line to the serial port (used by net.cpp during connect).
void provEmitStatus(const char *st, const char *ip);
