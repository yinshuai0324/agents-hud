idf_component_register(
    SRCS main.c ui.c idle.c font_cn_20.c net_cfg.c net_ws.c provision_ble.c
    INCLUDE_DIRS .
    PRIV_REQUIRES nvs_flash json bt esp_driver_gpio esp_wifi esp_netif esp_event
                  app_update board
                  espressif__esp_websocket_client espressif__mdns)
