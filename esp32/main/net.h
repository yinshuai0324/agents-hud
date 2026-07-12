#pragma once

#include "app_data.h"

/**
 * Start the BLE link: GATT server + advertising. The Mac daemon connects
 * and writes compact snapshot JSON to the RX characteristic every few
 * seconds; each write triggers `on_update`.
 */
void net_start(ahud_update_cb_t on_update);

/** Drop the current host and block it briefly so another one can connect. */
void net_switch_host(void);

/** Whether the dial is locked to one host (persisted in NVS). */
bool net_host_locked(void);

/** Lock to the currently connected host, or unlock if already locked. */
void net_host_lock_toggle(void);
