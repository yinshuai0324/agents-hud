idf_component_register(
    SRCS main.c bsp_custom.c ble_link.c ui.c idle.c font_cn_20.c
    INCLUDE_DIRS .
    PRIV_REQUIRES nvs_flash json bt esp_driver_gpio
                  espressif__esp_lcd_touch espressif__esp_lvgl_port)
