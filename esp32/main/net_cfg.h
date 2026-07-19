#pragma once

#include <stdbool.h>

/** Provisioned connection settings, stored in NVS namespace "ahud". */
typedef struct {
    char ssid[33];   /* WiFi SSID (802.11 max 32 bytes) */
    char pw[65];     /* WPA passphrase (max 64) */
    char url[128];   /* server base URL, e.g. "ws://192.168.1.10:4317" */
    char token[65];  /* shared auth token, "" when auth is disabled */
    char name[33];   /* host name picked at provisioning (mDNS preference) */
} net_cfg_t;

/** Load stored settings. Returns false when the device is unprovisioned. */
bool net_cfg_load(net_cfg_t *out);

/** Persist settings (called from the BLE provisioning write). */
bool net_cfg_save(const net_cfg_t *cfg);

/** Update just the server URL (mDNS rediscovery found a moved server). */
void net_cfg_save_url(const char *url);

/** Erase all provisioning (long-press BOOT / serial 'p'), keeps rotation. */
void net_cfg_erase(void);
