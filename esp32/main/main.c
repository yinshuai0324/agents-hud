#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs_flash.h"
#include "nvs.h"
#include "esp_log.h"
#include "esp_err.h"
#include "esp_system.h"
#include "driver/gpio.h"
#include "soc/rtc_cntl_reg.h"
#include "lvgl.h"
#include "bsp/esp-bsp.h"
#include "bsp/display.h"

#include "bsp_custom.h"
#include "idle.h"
#include "net.h"
#include "ui.h"

static const char *TAG = "ahud_main";

static void on_update(const ahud_snapshot_t *snap, ahud_net_state_t net)
{
    bsp_display_lock(0);
    ui_update(snap, net);
    bsp_display_unlock();
}

/**
 * USB console: 'b' reboots into ROM download mode (flash without touching
 * the BOOT button), 'r' plain reboot.
 */
static void console_task(void *arg)
{
    /* Non-blocking stdin polling. Never install the blocking USB-Serial-JTAG
     * VFS driver here: with no host reading the port, its TX ring fills up
     * and every ESP_LOG call in the system blocks forever. */
    fcntl(STDIN_FILENO, F_SETFL, fcntl(STDIN_FILENO, F_GETFL) | O_NONBLOCK);
    while (true) {
        char c = 0;
        if (read(STDIN_FILENO, &c, 1) == 1) {
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
            }
        } else {
            vTaskDelay(pdMS_TO_TICKS(100));
        }
    }
}

/**
 * BOOT key (GPIO0) as user button: short press rotates the display 90°.
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

    nvs_handle_t nvs = 0;
    uint8_t rot = 0;
    if (nvs_open("ahud", NVS_READWRITE, &nvs) == ESP_OK) {
        nvs_get_u8(nvs, "rot", &rot);
    }
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
            rot = (rot + 1) % 4;
            ESP_LOGI(TAG, "rotate display -> %d deg", rot * 90);
            bsp_display_lock(0);
            lv_display_set_rotation(lv_display_get_default(), (lv_display_rotation_t)rot);
            bsp_display_unlock();
            if (nvs) {
                nvs_set_u8(nvs, "rot", rot);
                nvs_commit(nvs);
            }
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

    ESP_ERROR_CHECK(bsp_custom_init());

    bsp_display_lock(-1);
    ui_init();
    bsp_display_unlock();

    net_start(on_update);

    xTaskCreate(console_task, "ahud_console", 4096, NULL, 3, NULL);
    xTaskCreate(button_task, "ahud_button", 4096, NULL, 3, NULL);
}
