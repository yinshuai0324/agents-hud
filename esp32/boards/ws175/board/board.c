#include "board.h"

#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_lcd_touch.h"
#include "esp_lvgl_port.h"
#include "bsp/touch.h"

static const char *TAG = "board_ws175";

/* Strip height per flush: 20*466*2 ≈ 18KB. sw_rotate allocates a second
 * buffer of the same size. Keeping both buffers internal prevents radio-time
 * display corruption while leaving enough internal RAM for WiFi/WS tasks. */
#define DRAW_BUF_LINES 20

const char *board_id(void)
{
    return BOARD_ID;
}

/* CO5300 requires even-aligned flush areas. */
static void rounder_event_cb(lv_event_t *e)
{
    lv_area_t *area = (lv_area_t *)lv_event_get_param(e);
    area->x1 &= ~1;
    area->y1 &= ~1;
    area->x2 |= 1;
    area->y2 |= 1;
}

esp_err_t board_init(void)
{
    lvgl_port_cfg_t lp = ESP_LVGL_PORT_INIT_CONFIG();
    /* LVGL never writes flash from its task. Its stack can therefore live in
     * PSRAM; the latency-sensitive display/rotation buffers remain internal. */
    lp.task_stack_caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
    if (lvgl_port_init(&lp) != ESP_OK) {
        ESP_LOGE(TAG, "lvgl_port_init failed");
        return ESP_FAIL;
    }

    bsp_display_config_t disp_config = {0};
    esp_lcd_panel_handle_t panel = NULL;
    esp_lcd_panel_io_handle_t io = NULL;
    if (bsp_display_new(&disp_config, &panel, &io) != ESP_OK) {
        ESP_LOGE(TAG, "bsp_display_new failed");
        return ESP_FAIL;
    }

    lvgl_port_display_cfg_t dcfg = {
        .io_handle = io,
        .panel_handle = panel,
        .buffer_size = BSP_LCD_H_RES * DRAW_BUF_LINES,
        .double_buffer = false,
        .hres = BSP_LCD_H_RES,
        .vres = BSP_LCD_V_RES,
        .color_format = LV_COLOR_FORMAT_RGB565,
        .rotation = { .swap_xy = false, .mirror_x = false, .mirror_y = false },
        .flags = {
            .buff_dma = true,     /* internal DMA RAM: immune to radio/PSRAM contention */
            .buff_spiram = false,
            .swap_bytes = true,
            .sw_rotate = true,    /* lv_display_set_rotation via BOOT key */
        },
    };
    lv_display_t *disp = lvgl_port_add_disp(&dcfg);
    if (disp == NULL) {
        /* Fallback: PSRAM buffer. May show stripes during WiFi bursts, but
         * a striped dashboard beats a dead screen. */
        ESP_LOGE(TAG, "internal DMA buffer alloc failed, falling back to PSRAM");
        dcfg.flags.buff_dma = false;
        dcfg.flags.buff_spiram = true;
        disp = lvgl_port_add_disp(&dcfg);
        if (disp == NULL) {
            ESP_LOGE(TAG, "lvgl_port_add_disp failed");
            return ESP_FAIL;
        }
    }
    lv_display_add_event_cb(disp, rounder_event_cb, LV_EVENT_INVALIDATE_AREA, NULL);

    esp_lcd_touch_handle_t tp = NULL;
    if (bsp_touch_new(NULL, &tp) == ESP_OK && tp) {
        const lvgl_port_touch_cfg_t tcfg = { .disp = disp, .handle = tp };
        lvgl_port_add_touch(&tcfg);
    } else {
        ESP_LOGW(TAG, "touch init failed (continuing)");
    }

    bsp_display_brightness_set(100);
    ESP_LOGI(TAG, "display ready (draw buffer in internal DMA RAM, %d lines)", DRAW_BUF_LINES);
    return ESP_OK;
}
