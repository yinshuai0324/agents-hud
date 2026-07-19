#pragma once

#include <stdbool.h>
#include <stdint.h>

/** Parsed subset of the AgentsHUD /api/snapshot payload the dial displays. */
typedef struct {
    char plan[32];
    char model[40];
    int u5h_percent;        // 0..100
    int u5h_reset_min;
    long long u5h_tokens_used;
    long long u5h_burn_per_min;
    bool u5h_live;          // source == "live"
    int u7d_percent;        // -1 when the server has no 7d window
    int u7d_reset_min;
    long long today_tokens;
    int s_working;
    int s_waiting;
    int s_notify;
    int s_error;
    int s_quiet;
    int s_total;
    /** Hostname of the computer pushing data ("" if unknown). */
    char host[24];
    /** Dominant session state: working/waiting/notify/error/quiet ("" unknown). */
    char dominant[12];
} ahud_snapshot_t;

typedef enum {
    AHUD_NET_PROVISIONING,       /* unprovisioned: BLE pairing mode */
    AHUD_NET_WIFI_CONNECTING,    /* joining WiFi / no server link yet */
    AHUD_NET_SERVER_UNREACHABLE, /* WiFi up but no fresh data from the server */
    AHUD_NET_OK,
} ahud_net_state_t;

/** Called from the net task with the display lock NOT held. */
typedef void (*ahud_update_cb_t)(const ahud_snapshot_t *snap, ahud_net_state_t net);
