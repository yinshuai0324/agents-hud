#include "net.h"

#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "cJSON.h"
#include "nvs.h"

#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "ahud_ble";

/* Base name; the advertised name gets a per-device MAC suffix so multiple
 * dials are distinguishable, e.g. "AgentsHUD-F232". */
#define DEVICE_NAME_BASE "AgentsHUD"
static char s_device_name[24] = DEVICE_NAME_BASE;
/* Data considered stale when no write arrives for this long. */
#define STALE_MS 12000

/* Service 41485544-6469-616c-2d64-617461-... ("AHUD dial-data"), RX char ..02.
 * NimBLE stores 128-bit UUIDs little-endian (reversed byte order). */
static const ble_uuid128_t SVC_UUID =
    BLE_UUID128_INIT(0x01, 0x00, 0x00, 0x61, 0x74, 0x61, 0x64, 0x2d,
                     0x6c, 0x61, 0x69, 0x64, 0x44, 0x55, 0x48, 0x41);
static const ble_uuid128_t RX_UUID =
    BLE_UUID128_INIT(0x02, 0x00, 0x00, 0x61, 0x74, 0x61, 0x64, 0x2d,
                     0x6c, 0x61, 0x69, 0x64, 0x44, 0x55, 0x48, 0x41);

static ahud_update_cb_t s_on_update;
static volatile bool s_connected;
static volatile uint32_t s_last_data_tick;
static uint8_t s_own_addr_type;
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;

/* Host selection: the dial decides which computer it accepts.
 *  - s_cur_host:    hostname from the latest payload
 *  - s_locked_host: only this host is accepted (persisted in NVS; "" = any)
 *  - s_block_host:  temporarily rejected host (the "switch computer" button) */
static char s_cur_host[24];
static char s_locked_host[24];
static char s_block_host[24];
static uint32_t s_block_until_tick;

#define BLOCK_MS 120000

static void locked_host_save(const char *host)
{
    nvs_handle_t h;
    if (nvs_open("ahud", NVS_READWRITE, &h) != ESP_OK) return;
    if (host && host[0]) nvs_set_str(h, "lockhost", host);
    else nvs_erase_key(h, "lockhost");
    nvs_commit(h);
    nvs_close(h);
}

static void locked_host_load(void)
{
    nvs_handle_t h;
    if (nvs_open("ahud", NVS_READONLY, &h) != ESP_OK) return;
    size_t len = sizeof(s_locked_host);
    if (nvs_get_str(h, "lockhost", s_locked_host, &len) != ESP_OK) {
        s_locked_host[0] = '\0';
    }
    nvs_close(h);
}

/** True if this host must be rejected right now. */
static bool host_rejected(const char *host)
{
    if (!host[0]) return false;
    if (s_locked_host[0] && strcmp(host, s_locked_host) != 0) return true;
    if (s_block_host[0] && strcmp(host, s_block_host) == 0) {
        if ((int32_t)(xTaskGetTickCount() * portTICK_PERIOD_MS - s_block_until_tick) < 0) {
            return true;
        }
        s_block_host[0] = '\0'; /* block expired */
    }
    return false;
}

void net_switch_host(void)
{
    if (!s_cur_host[0]) return;
    strlcpy(s_block_host, s_cur_host, sizeof(s_block_host));
    s_block_until_tick = xTaskGetTickCount() * portTICK_PERIOD_MS + BLOCK_MS;
    ESP_LOGW(TAG, "switch host: blocking \"%s\" for %ds", s_block_host, BLOCK_MS / 1000);
    if (s_conn_handle != BLE_HS_CONN_HANDLE_NONE) {
        ble_gap_terminate(s_conn_handle, BLE_ERR_REM_USER_CONN_TERM);
    }
}

bool net_host_locked(void)
{
    return s_locked_host[0] != '\0';
}

void net_host_lock_toggle(void)
{
    if (s_locked_host[0]) {
        s_locked_host[0] = '\0';
        locked_host_save(NULL);
        ESP_LOGI(TAG, "host unlocked");
    } else if (s_cur_host[0]) {
        strlcpy(s_locked_host, s_cur_host, sizeof(s_locked_host));
        locked_host_save(s_locked_host);
        ESP_LOGI(TAG, "locked to host \"%s\"", s_locked_host);
    }
}

static long long json_ll(const cJSON *o, const char *k)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    return cJSON_IsNumber(v) ? (long long)v->valuedouble : 0;
}

static void json_str(const cJSON *o, const char *k, char *out, size_t cap)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    if (cJSON_IsString(v) && v->valuestring) strlcpy(out, v->valuestring, cap);
    else out[0] = '\0';
}

/* Compact payload from the daemon:
 * {"p5":52,"r5":161,"p7":27,"r7":5231,"tt":163962,"bu":15163,"lv":1,
 *  "w":1,"n":2,"wa":0,"e":0,"q":0,"to":3,"m":"Fable 5","pl":"Max (5x)"} */
static bool parse_payload(const char *body, ahud_snapshot_t *out)
{
    cJSON *root = cJSON_Parse(body);
    if (!root) return false;
    memset(out, 0, sizeof(*out));
    out->u5h_percent = (int)json_ll(root, "p5");
    out->u5h_reset_min = (int)json_ll(root, "r5");
    const cJSON *p7 = cJSON_GetObjectItemCaseSensitive(root, "p7");
    out->u7d_percent = cJSON_IsNumber(p7) ? (int)p7->valuedouble : -1;
    out->u7d_reset_min = (int)json_ll(root, "r7");
    out->today_tokens = json_ll(root, "tt");
    out->u5h_burn_per_min = json_ll(root, "bu");
    out->u5h_live = json_ll(root, "lv") != 0;
    out->s_working = (int)json_ll(root, "w");
    out->s_notify = (int)json_ll(root, "n");
    out->s_waiting = (int)json_ll(root, "wa");
    out->s_error = (int)json_ll(root, "e");
    out->s_quiet = (int)json_ll(root, "q");
    out->s_total = (int)json_ll(root, "to");
    json_str(root, "m", out->model, sizeof(out->model));
    json_str(root, "pl", out->plan, sizeof(out->plan));
    json_str(root, "h", out->host, sizeof(out->host));
    cJSON_Delete(root);
    return true;
}

static int rx_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                        struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;

    static char buf[1024];
    uint16_t len = 0;
    if (ble_hs_mbuf_to_flat(ctxt->om, buf, sizeof(buf) - 1, &len) != 0) {
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    buf[len] = '\0';

    ahud_snapshot_t snap;
    if (parse_payload(buf, &snap)) {
        if (host_rejected(snap.host)) {
            ESP_LOGW(TAG, "rejecting host \"%s\" (%s)", snap.host,
                     s_locked_host[0] ? "locked to another" : "switched away");
            ble_gap_terminate(conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            return 0;
        }
        strlcpy(s_cur_host, snap.host, sizeof(s_cur_host));
        s_last_data_tick = xTaskGetTickCount();
        ESP_LOGI(TAG, "data ok: 5h=%d%% 7d=%d%% sessions=%d host=%s len=%u",
                 snap.u5h_percent, snap.u7d_percent, snap.s_total, snap.host, len);
        s_on_update(&snap, AHUD_NET_OK);
    } else {
        ESP_LOGW(TAG, "bad payload (%u bytes)", len);
    }
    return 0;
}

static const struct ble_gatt_svc_def GATT_SVCS[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &SVC_UUID.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &RX_UUID.u,
                .access_cb = rx_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            { 0 },
        },
    },
    { 0 },
};

static void start_advertising(void);

static int gap_event_cb(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            ESP_LOGI(TAG, "host connected");
            s_connected = true;
            s_conn_handle = event->connect.conn_handle;
        } else {
            start_advertising();
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGW(TAG, "host disconnected (reason %d)", event->disconnect.reason);
        s_connected = false;
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_cur_host[0] = '\0';
        start_advertising();
        break;
    default:
        break;
    }
    return 0;
}

static void start_advertising(void)
{
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

    uint8_t addr[6] = {0};
    if (ble_hs_id_copy_addr(s_own_addr_type, addr, NULL) == 0) {
        snprintf(s_device_name, sizeof(s_device_name), "%s-%02X%02X",
                 DEVICE_NAME_BASE, addr[1], addr[0]);
        ble_svc_gap_device_name_set(s_device_name);
    }
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

/* Drives the "waiting for connection / data stale" UI states. */
static void status_task(void *arg)
{
    while (true) {
        if (!s_connected) {
            s_on_update(NULL, AHUD_NET_WIFI_CONNECTING); /* = waiting for BLE */
        } else {
            uint32_t age = (xTaskGetTickCount() - s_last_data_tick) * portTICK_PERIOD_MS;
            if (age > STALE_MS) {
                s_on_update(NULL, AHUD_NET_SERVER_UNREACHABLE);
            }
        }
        vTaskDelay(pdMS_TO_TICKS(2000));
    }
}

void net_start(ahud_update_cb_t on_update)
{
    s_on_update = on_update;
    s_last_data_tick = xTaskGetTickCount();
    locked_host_load();
    if (s_locked_host[0]) ESP_LOGI(TAG, "locked to host \"%s\"", s_locked_host);

    ESP_ERROR_CHECK(nimble_port_init());

    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.reset_cb = on_reset;

    ble_svc_gap_init();
    ble_svc_gatt_init();
    ESP_ERROR_CHECK(ble_gatts_count_cfg(GATT_SVCS));
    ESP_ERROR_CHECK(ble_gatts_add_svcs(GATT_SVCS));
    ble_svc_gap_device_name_set(DEVICE_NAME_BASE);

    nimble_port_freertos_init(host_task);
    xTaskCreate(status_task, "ahud_status", 4096, NULL, 4, NULL);
}
