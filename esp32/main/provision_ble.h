#pragma once

#include <stdbool.h>
#include "net_cfg.h"

/**
 * BLE provisioning service (the only remaining BLE role — data moved to WiFi).
 *
 * GATT layout (service UUID shared with the legacy data link so the Mac's
 * scanner keeps matching):
 *   41485544-...0001  service "AHUD"
 *   41485544-...0003  WRITE      provisioning request JSON
 *                     {"v":1,"ssid":"..","pw":"..","url":"ws://ip:4317",
 *                      "token":"..","name":"MacBook-Pro"}
 *   41485544-...0004  READ|NOTIFY status JSON
 *                     {"st":"idle|connecting|got_ip|ws_ok|bad_pass|
 *                            ap_not_found|server_fail","ip":"..."}
 *   41485544-...0005  READ       device info JSON
 *                     {"board":"ws175","fw":"0.2.0","id":"F232"}
 */

/** Called (from the NimBLE task) when a valid provisioning request arrives. */
typedef void (*provision_request_cb_t)(const net_cfg_t *cfg);

/** Start advertising + GATT. Safe to call when already running. Returns false
 * instead of aborting when memory is unavailable, so USB remains usable. */
bool provision_ble_start(provision_request_cb_t on_request);

/** Stop NimBLE entirely and free its memory (provisioning done). */
void provision_ble_stop(void);

bool provision_ble_running(void);

/** Push a status update to the status characteristic (notifies if subscribed). */
void provision_ble_set_status(const char *st, const char *ip);
