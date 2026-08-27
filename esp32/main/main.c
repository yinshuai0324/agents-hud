#include <stdio.h>
#include <fcntl.h>
#include <string.h>
#include <unistd.h>

#include "freertos/FreeRTOS.h"
#include "freertos/idf_additions.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_log.h"
#include "esp_err.h"
#include "esp_heap_caps.h"
#include "esp_system.h"
#include "esp_app_desc.h"
#include "driver/gpio.h"
#include "soc/rtc_cntl_reg.h"
#include "cJSON.h"
#include "lvgl.h"

#include "board.h"
#include "idle.h"
#include "net.h"
#include "ui.h"

static const char *TAG = "ahud_main";
static uint8_t s_boot_rotation;

#define CONSOLE_LINE_CAP 600

static void on_update(const ahud_snapshot_t *snap, ahud_net_state_t net)
{
    bsp_display_lock(0);
    ui_update(snap, net);
    bsp_display_unlock();
}

static void console_json_str(const cJSON *root, const char *key,
                             char *out, size_t cap)
{
    const cJSON *value = cJSON_GetObjectItemCaseSensitive(root, key);
    if (cJSON_IsString(value) && value->valuestring) {
        strlcpy(out, value->valuestring, cap);
    } else {
        out[0] = '\0';
    }
}

static void console_emit_status(const char *status)
{
    printf("{\"t\":\"st\",\"st\":\"%s\",\"ip\":\"\"}\n", status);
    fflush(stdout);
}

static void console_emit_info(void)
{
    printf("{\"t\":\"info\",\"board\":\"%s\",\"fw\":\"%s\",\"id\":\"%s\"}\n",
           board_id(), esp_app_get_description()->version, net_device_id());
    fflush(stdout);
}

static void console_handle_json(const char *line)
{
    cJSON *root = cJSON_Parse(line);
    if (!root) return;

    const cJSON *type = cJSON_GetObjectItemCaseSensitive(root, "t");
    const char *t = cJSON_IsString(type) && type->valuestring
        ? type->valuestring : "";

    if (strcmp(t, "info?") == 0) {
        console_emit_info();
    } else if (strcmp(t, "prov") == 0) {
        net_cfg_t cfg;
        memset(&cfg, 0, sizeof(cfg));
        console_json_str(root, "ssid", cfg.ssid, sizeof(cfg.ssid));
        console_json_str(root, "pw", cfg.pw, sizeof(cfg.pw));
        console_json_str(root, "url", cfg.url, sizeof(cfg.url));
        console_json_str(root, "token", cfg.token, sizeof(cfg.token));
        console_json_str(root, "name", cfg.name, sizeof(cfg.name));
        if (cfg.ssid[0] == '\0' || cfg.url[0] == '\0' ||
            !net_provision_from_serial(&cfg)) {
            console_emit_status("bad_request");
        }
    } else if (strcmp(t, "reset") == 0) {
        cJSON_Delete(root);
        if (net_request_reset_provisioning()) {
            console_emit_status("idle");
        } else {
            console_emit_status("bad_request");
        }
        return;
    }
    cJSON_Delete(root);
}

static void console_handle_command(char c)
{
    if (c == 'b') {
        ESP_LOGW(TAG, "rebooting into download mode");
        vTaskDelay(pdMS_TO_TICKS(100));
        REG_WRITE(RTC_CNTL_OPTION1_REG, RTC_CNTL_FORCE_DOWNLOAD_BOOT);
        esp_restart();
    } else if (c == 'r') {
        ESP_LOGW(TAG, "rebooting");
        vTaskDelay(pdMS_TO_TICKS(100));
        esp_restart();
    } else if (c == 'z') {
        ESP_LOGW(TAG, "forcing idle sleep");
        idle_force_sleep();
    } else if (c == 'p') {
        net_request_reset_provisioning();
    }
}

/**
 * USB console: line-delimited JSON supports device discovery and WiFi
 * provisioning. The legacy single-character b/r/p/z commands remain
 * immediate so firmware flashing does not depend on a trailing newline.
 */
static void console_task(void *arg)
{
    /* Keep the driverless USB-Serial-JTAG VFS in its nominal blocking mode.
     * Its low-level reader still returns immediately when the FIFO is empty,
     * while ESP-IDF 5.5's O_NONBLOCK path skips the hardware FIFO entirely.
     * Do not install the buffered driver here: with no host reading the port,
     * its TX ring can make system log writes block indefinitely. */
    int flags = fcntl(STDIN_FILENO, F_GETFL);
    fcntl(STDIN_FILENO, F_SETFL, flags & ~O_NONBLOCK);
    ESP_LOGI(TAG, "USB console ready");
    char line[CONSOLE_LINE_CAP];
    size_t line_len = 0;
    bool discard_line = false;
    while (true) {
        char rx[128];
        ssize_t count = read(STDIN_FILENO, rx, sizeof(rx));
        if (count > 0) {
            for (ssize_t i = 0; i < count; i++) {
                char c = rx[i];
                if (discard_line) {
                    if (c == '\n' || c == '\r') discard_line = false;
                    continue;
                }
                if (line_len == 0) {
                    if (c == '{') {
                        line[line_len++] = c;
                    } else if (c != '\n' && c != '\r') {
                        console_handle_command(c);
                    }
                } else if (c == '\n' || c == '\r') {
                    line[line_len] = '\0';
                    console_handle_json(line);
                    line_len = 0;
                } else if (line_len < sizeof(line) - 1) {
                    line[line_len++] = c;
                } else {
                    line_len = 0;
                    discard_line = true;
                    console_emit_status("bad_request");
                }
            }
        } else {
            vTaskDelay(pdMS_TO_TICKS(20));
        }
    }
}

/**
 * BOOT key (GPIO0) as user button: short press rotates the display 90°,
 * long press (>=3s) erases provisioning and reboots into pairing mode.
 * The orientation persists in NVS across reboots.
 */
static void button_task(void *arg)
{
    gpio_config_t io = {
        .pin_bit_mask = 1ULL << GPIO_NUM_0,
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_ENABLE,
    };
    gpio_config(&io);

    uint8_t rot = s_boot_rotation;
    rot %= 4;
    if (rot != 0) {
        bsp_display_lock(0);
        lv_display_set_rotation(lv_display_get_default(), (lv_display_rotation_t)rot);
        bsp_display_unlock();
    }

    int last = 1;
    while (true) {
        int v = gpio_get_level(GPIO_NUM_0);
        if (last == 1 && v == 0) { /* falling edge = press */
            if (idle_consume_wake()) { /* asleep: press only wakes */
                vTaskDelay(pdMS_TO_TICKS(300));
                last = 0;
                continue;
            }
            /* Held >=3s -> factory re-pair; released earlier -> rotate. */
            uint32_t held_ms = 0;
            while (gpio_get_level(GPIO_NUM_0) == 0 && held_ms < 3000) {
                vTaskDelay(pdMS_TO_TICKS(50));
                held_ms += 50;
            }
            if (held_ms >= 3000) {
                ESP_LOGW(TAG, "BOOT long press -> reset provisioning");
                if (net_request_reset_provisioning()) {
                    vTaskSuspend(NULL);
                }
                continue;
            }
            rot = (rot + 1) % 4;
            ESP_LOGI(TAG, "rotate display -> %d deg", rot * 90);
            bsp_display_lock(0);
            lv_display_set_rotation(lv_display_get_default(), (lv_display_rotation_t)rot);
            bsp_display_unlock();
            net_save_rotation(rot);
            vTaskDelay(pdMS_TO_TICKS(300)); /* debounce + repeat guard */
        }
        last = v;
        vTaskDelay(pdMS_TO_TICKS(30));
    }
}

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ESP_ERROR_CHECK(nvs_flash_init());
    }

    nvs_handle_t settings = 0;
    if (nvs_open("ahud", NVS_READONLY, &settings) == ESP_OK) {
        nvs_get_u8(settings, "rot", &s_boot_rotation);
        nvs_close(settings);
    }
    s_boot_rotation %= 4;

    ESP_ERROR_CHECK(board_init());

    /* Create USB/button tasks before ui_init/net_start, with their stacks in
     * PSRAM. Flash-writing operations are forwarded to the internal-stack
     * network task because the flash cache temporarily makes PSRAM unavailable. */
    const UBaseType_t task_stack_caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
    BaseType_t console_ok = xTaskCreateWithCaps(
        console_task, "ahud_console", 4096, NULL, 3, NULL, task_stack_caps);
    BaseType_t button_ok = xTaskCreateWithCaps(
        button_task, "ahud_button", 4096, NULL, 3, NULL, task_stack_caps);
    if (console_ok != pdPASS || button_ok != pdPASS) {
        ESP_LOGE(TAG, "task create FAILED: console=%d button=%d",
                 (int)console_ok, (int)button_ok);
    }

    bsp_display_lock(-1);
    ui_init();
    bsp_display_unlock();

    net_start(on_update);

    ESP_LOGI(TAG, "free heap: internal=%u psram=%u largest_internal=%u",
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL));
}
