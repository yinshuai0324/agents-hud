# Board HAL: Waveshare ESP32-S3-Touch-AMOLED-1.75 (466x466 round AMOLED).
# Every board ships a component named "board" under boards/<id>/; the top-level
# CMakeLists picks one via EXTRA_COMPONENT_DIRS (idf.py -DAHUD_BOARD=<id>).
# Application code only includes board.h — that is the porting boundary.
idf_component_register(
    SRCS board.c
    INCLUDE_DIRS include
    REQUIRES waveshare__esp32_s3_touch_amoled_1_75 espressif__esp_lvgl_port
    PRIV_REQUIRES espressif__esp_lcd_touch)
