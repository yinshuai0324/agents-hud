#pragma once

#include "esp_err.h"
/* Display lock/unlock and brightness come from the board's BSP; re-exported
 * here so application code includes board.h only (the porting boundary). */
#include "bsp/esp-bsp.h"
#include "bsp/display.h"

/** Stable board model id, used in firmware assets / WS hello / BLE info. */
#define BOARD_ID "ws175"

/** Panel geometry (the UI currently assumes the 466x466 round AMOLED). */
#define BOARD_DISPLAY_WIDTH  466
#define BOARD_DISPLAY_HEIGHT 466

/**
 * Display + touch + LVGL init with the draw buffer in internal DMA RAM
 * (not PSRAM). Radio traffic (WiFi/BLE) stalls PSRAM/cache and drops QSPI
 * flush strips, which shows as black/white bands; internal RAM avoids it.
 * Replaces bsp_display_start(); bsp_display_lock/unlock still work.
 */
esp_err_t board_init(void);

/** Board model id (BOARD_ID) — for hello messages and the detail page. */
const char *board_id(void);
