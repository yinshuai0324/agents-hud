#pragma once

#include "esp_err.h"

/**
 * Display + touch + LVGL init with the draw buffer in internal DMA RAM
 * (not PSRAM). WiFi traffic stalls PSRAM/cache and drops QSPI flush
 * strips, which shows as black/white bands; internal RAM avoids it.
 * Replaces bsp_display_start(); bsp_display_lock/unlock still work.
 */
esp_err_t bsp_custom_init(void);
