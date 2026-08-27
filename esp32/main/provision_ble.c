#include "provision_ble.h"

#include <string.h>
#include <stdio.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_app_desc.h"
#include "cJSON.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "board.h"
#include "net.h"

static const char *TAG = "ahud_prov";

#define DEVICE_NAME_BASE "AgentsHUD"
static char s_device_name[24] = DEVICE_NAME_BASE;

/* Service 41485544-... ("AHUD..."), same base as the legacy data service.
 * NimBLE stores 128-bit UUIDs little-endian (reversed byte order). */
static const ble_uuid128_t SVC_UUID =
    BLE_UUID128_INIT(0x01, 0x00, 0x00, 0x61, 0x74, 0x61, 0x64, 0x2d,
                     0x6c, 0x61, 0x69, 0x64, 0x44, 0x55, 0x48, 0x41);
static const ble_uuid128_t CFG_UUID = /* ...0003 provisioning request */
    BLE_UUID128_INIT(0x03, 0x00, 0x00, 0x61, 0x74, 0x61, 0x64, 0x2d,
                     0x6c, 0x61, 0x69, 0x64, 0x44, 0x55, 0x48, 0x41);
static const ble_uuid128_t STATUS_UUID = /* ...0004 status read/notify */
    BLE_UUID128_INIT(0x04, 0x00, 0x00, 0x61, 0x74, 0x61, 0x64, 0x2d,
                     0x6c, 0x61, 0x69, 0x64, 0x44, 0x55, 0x48, 0x41);
static const ble_uuid128_t INFO_UUID = /* ...0005 device info read */
    BLE_UUID128_INIT(0x05, 0x00, 0x00, 0x61, 0x74, 0x61, 0x64, 0x2d,
                     0x6c, 0x61, 0x69, 0x64, 0x44, 0x55, 0x48, 0x41);

static provision_request_cb_t s_on_request;
static volatile bool s_running;
static uint8_t s_own_addr_type;
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint16_t s_status_val_handle;
static char s_status_json[96] = "{\"st\":\"idle\",\"ip\":\"\"}";

static void start_advertising(void);

static void json_str(const cJSON *o, const char *k, char *out, size_t cap)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    if (cJSON_IsString(v) && v->valuestring) strlcpy(out, v->valuestring, cap);
    else out[0] = '\0';
}

static int cfg_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                         struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;

    static char buf[512];
    uint16_t len = 0;
    if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf) - 1, &len) != 0) {
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    buf[len] = '\0';

    cJSON *root = cJSON_Parse(buf);
    if (!root) {
        ESP_LOGW(TAG, "bad provisioning JSON (%u bytes)", len);
        return BLE_ATT_ERR_UNLIKELY;
    }
    net_cfg_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    json_str(root, "ssid", cfg.ssid, sizeof(cfg.ssid));
    json_str(root, "pw", cfg.pw, sizeof(cfg.pw));
    json_str(root, "url", cfg.url, sizeof(cfg.url));
    json_str(root, "token", cfg.token, sizeof(cfg.token));
    json_str(root, "name", cfg.name, sizeof(cfg.name));
    cJSON_Delete(root);

    if (cfg.ssid[0] == '\0' || cfg.url[0] == '\0') {
        ESP_LOGW(TAG, "provisioning request missing ssid/url");
        return BLE_ATT_ERR_UNLIKELY;
    }
    ESP_LOGI(TAG, "provisioning request: ssid=%s url=%s", cfg.ssid, cfg.url);
    if (s_on_request) s_on_request(&cfg);
    return 0;
}

static int status_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                            struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) return BLE_ATT_ERR_UNLIKELY;
    return os_mbuf_append(ctxt->om, s_status_json, strlen(s_status_json)) == 0
        ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

static int info_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                          struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) return BLE_ATT_ERR_UNLIKELY;
    char info[96];
    snprintf(info, sizeof(info), "{\"board\":\"%s\",\"fw\":\"%s\",\"id\":\"%s\"}",
             board_id(), esp_app_get_description()->version, net_device_id());
    return os_mbuf_append(ctxt->om, info, strlen(info)) == 0
        ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

static const struct ble_gatt_svc_def GATT_SVCS[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &SVC_UUID.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &CFG_UUID.u,
                .access_cb = cfg_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &STATUS_UUID.u,
                .access_cb = status_access_cb,
                .val_handle = &s_status_val_handle,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY,
            },
            {
                .uuid = &INFO_UUID.u,
                .access_cb = info_access_cb,
                .flags = BLE_GATT_CHR_F_READ,
            },
            { 0 },
        },
    },
    { 0 },
};

void provision_ble_set_status(const char *st, const char *ip)
{
    snprintf(s_status_json, sizeof(s_status_json), "{\"st\":\"%s\",\"ip\":\"%s\"}",
             st, ip ? ip : "");
    ESP_LOGI(TAG, "status -> %s", s_status_json);
    if (s_running && s_conn_handle != BLE_HS_CONN_HANDLE_NONE) {
        struct os_mbuf *om = ble_hs_mbuf_from_flat(s_status_json, strlen(s_status_json));
        if (om) ble_gatts_notify_custom(s_conn_handle, s_status_val_handle, om);
    }
}

static int gap_event_cb(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            ESP_LOGI(TAG, "provisioner connected");
            s_conn_handle = event->connect.conn_handle;
        } else {
            start_advertising();
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "provisioner disconnected (reason %d)", event->disconnect.reason);
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        if (s_running) start_advertising();
        break;
    default:
        break;
    }
    return 0;
}

static void start_advertising(void)
{
    ble_gap_adv_stop();
    struct ble_gap_adv_params params = {
        .conn_mode = BLE_GAP_CONN_MODE_UND,
        .disc_mode = BLE_GAP_DISC_MODE_GEN,
    };

    struct ble_hs_adv_fields adv = {0};
    adv.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    adv.name = (const uint8_t *)s_device_name;
    adv.name_len = strlen(s_device_name);
    adv.name_is_complete = 1;
    ble_gap_adv_set_fields(&adv);

    /* 128-bit service UUID goes in the scan response (no room in ADV). */
    struct ble_hs_adv_fields rsp = {0};
    rsp.uuids128 = (ble_uuid128_t *)&SVC_UUID;
    rsp.num_uuids128 = 1;
    rsp.uuids128_is_complete = 1;
    ble_gap_adv_rsp_set_fields(&rsp);

    int rc = ble_gap_adv_start(s_own_addr_type, NULL, BLE_HS_FOREVER,
                               &params, gap_event_cb, NULL);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGE(TAG, "adv start failed: %d", rc);
    } else {
        ESP_LOGI(TAG, "advertising as \"%s\"", s_device_name);
    }
}

static void on_sync(void)
{
    ble_hs_util_ensure_addr(0);
    ble_hs_id_infer_auto(0, &s_own_addr_type);
    /* Same name format as before; the id itself comes from the WiFi MAC (see
     * net_device_id) so it stays stable whether or not BLE is running. */
    snprintf(s_device_name, sizeof(s_device_name), "%s-%s",
             DEVICE_NAME_BASE, net_device_id());
    ble_svc_gap_device_name_set(s_device_name);
    start_advertising();
}

static void on_reset(int reason)
{
    ESP_LOGW(TAG, "nimble reset, reason %d", reason);
}

static void host_task(void *param)
{
    nimble_port_run();
    nimble_port_freertos_deinit();
}

bool provision_ble_start(provision_request_cb_t on_request)
{
    if (s_running) return true;
    s_on_request = on_request;

    esp_err_t err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NimBLE init failed: %s", esp_err_to_name(err));
        return false;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    ESP_ERROR_CHECK(ble_gatts_count_cfg(GATT_SVCS));
    ESP_ERROR_CHECK(ble_gatts_add_svcs(GATT_SVCS));
    ble_svc_gap_device_name_set(DEVICE_NAME_BASE);

    nimble_port_freertos_init(host_task);
    s_running = true;
    ESP_LOGI(TAG, "provisioning BLE started");
    return true;
}

void provision_ble_stop(void)
{
    if (!s_running) return;
    s_running = false;
    s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
    ble_gap_adv_stop();
    if (nimble_port_stop() == 0) {
        nimble_port_deinit();
        ESP_LOGI(TAG, "provisioning BLE stopped, memory released");
    } else {
        ESP_LOGW(TAG, "nimble_port_stop failed; BLE left running");
        s_running = true;
    }
}

bool provision_ble_running(void)
{
    return s_running;
}
