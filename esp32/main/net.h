#pragma once

#include "app_data.h"
#include "net_cfg.h"

/**
 * Start the network layer. Unprovisioned devices advertise a BLE provisioning
 * service (the Mac app writes WiFi credentials + server URL); provisioned
 * devices join WiFi and stream compact snapshots from the server's /device
 * WebSocket. Each received snapshot triggers `on_update`.
 */
void net_start(ahud_update_cb_t on_update);

/** Device id shown on the dial, e.g. "F232" (WiFi MAC suffix). */
const char *net_device_id(void);

/** Erase provisioning and reboot into pairing mode (long-press BOOT / 'p'). */
void net_reset_provisioning(void);

/** Queue the same reset from a task whose stack may live in external RAM. */
bool net_request_reset_provisioning(void);

/** Queue rotation persistence on the internal-stack network task. */
bool net_save_rotation(uint8_t rotation);

/**
 * Apply credentials received over USB serial. Status updates are emitted as
 * line-delimited JSON on the console until the device reaches ws_ok or the
 * provisioning attempt is replaced.
 */
bool net_provision_from_serial(const net_cfg_t *cfg);
