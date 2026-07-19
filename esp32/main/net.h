#pragma once

#include "app_data.h"

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
