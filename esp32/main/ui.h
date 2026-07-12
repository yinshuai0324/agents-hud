#pragma once

#include "app_data.h"

/** Build the dashboard. Call with the LVGL/display lock held. */
void ui_init(void);

/**
 * Refresh the dashboard. Call with the LVGL/display lock held.
 * `snap` may be NULL (keeps last data, only updates the status line).
 */
void ui_update(const ahud_snapshot_t *snap, ahud_net_state_t net);
