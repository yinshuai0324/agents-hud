#pragma once

#include "app_data.h"

/**
 * Start the BLE link: GATT server + advertising. The Mac daemon connects
 * and writes compact snapshot JSON to the RX characteristic every few
 * seconds; each write triggers `on_update`.
 */
void net_start(ahud_update_cb_t on_update);

/** BT MAC suffix shown on the dial, e.g. "F232" ("" until BLE is up). */
const char *net_device_id(void);
