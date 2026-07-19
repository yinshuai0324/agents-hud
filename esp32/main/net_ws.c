#include "net.h"

#include <string.h>
#include <stdio.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/event_groups.h"
#include "esp_log.h"
#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_netif.h"
#include "esp_mac.h"
#include "esp_system.h"
#include "esp_app_desc.h"
#include "esp_websocket_client.h"
#include "mdns.h"
#include "cJSON.h"

#include "board.h"
#include "net_cfg.h"
#include "provision_ble.h"

static const char *TAG = "ahud_net";

/* Data considered stale when nothing arrives for this long. The server pushes
 * every 3s; short WS reconnects stay under this so the screen doesn't flash. */
#define STALE_MS 30000
/* WS down for this long (WiFi up) -> try mDNS rediscovery of a moved server. */
#define REDISCOVER_MS 30000
/* Consecutive auth-type WiFi failures before falling back to pairing mode. */
#define MAX_AUTH_FAILS 6
/* Keep BLE up this long after ws_ok so the provisioner reads the result. */
#define PROV_LINGER_MS 10000

static ahud_update_cb_t s_on_update;
static char s_device_id[8];
static net_cfg_t s_cfg;
static volatile bool s_have_cfg;

static EventGroupHandle_t s_events;
#define EV_GOT_IP        BIT0
#define EV_WIFI_FAIL     BIT1
#define EV_PROV_REQUEST  BIT2

static esp_websocket_client_handle_t s_ws;
static volatile bool s_ws_connected;
static volatile uint32_t s_last_data_tick;
static volatile uint32_t s_ws_down_since_tick;
static volatile bool s_wifi_up;
static volatile int s_auth_fails;
static volatile int s_last_disc_reason;
static net_cfg_t s_pending_cfg;         /* written by BLE, consumed by net task */
static volatile bool s_provisioning;    /* pairing mode active */
static volatile uint32_t s_prov_ok_tick; /* when ws_ok was reported over BLE */

const char *net_device_id(void)
{
    return s_device_id;
}

void net_reset_provisioning(void)
{
    ESP_LOGW(TAG, "erasing provisioning, rebooting into pairing mode");
    net_cfg_erase();
    vTaskDelay(pdMS_TO_TICKS(200));
    esp_restart();
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

/* Compact payload, identical to the legacy BLE format plus "t":"snap":
 * {"t":"snap","p5":52,"r5":161,"p7":27,"r7":5231,"tt":163962,"bu":15163,
 *  "lv":1,"w":1,"n":2,"wa":0,"e":0,"q":0,"to":3,"m":"Fable 5","pl":"Max (5x)"} */
static bool parse_payload(const char *body, ahud_snapshot_t *out)
{
    cJSON *root = cJSON_Parse(body);
    if (!root) return false;
    /* Typed messages: only "snap" carries display data; ignore others
     * (hi/anim/text... future extensions) without error. */
    const cJSON *t = cJSON_GetObjectItemCaseSensitive(root, "t");
    if (cJSON_IsString(t) && t->valuestring && strcmp(t->valuestring, "snap") != 0) {
        cJSON_Delete(root);
        return false;
    }
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
    json_str(root, "d", out->dominant, sizeof(out->dominant));
    cJSON_Delete(root);
    return true;
}

/* ---------------------------------------------------------------- WebSocket */

static void ws_handle_text(const char *body)
{
    ahud_snapshot_t snap;
    if (parse_payload(body, &snap)) {
        s_last_data_tick = xTaskGetTickCount();
        s_on_update(&snap, AHUD_NET_OK);
        if (s_provisioning && s_prov_ok_tick == 0) {
            provision_ble_set_status("ws_ok", NULL);
            s_prov_ok_tick = xTaskGetTickCount();
        }
    }
}

static void ws_event_handler(void *arg, esp_event_base_t base,
                             int32_t event_id, void *event_data)
{
    esp_websocket_event_data_t *data = event_data;
    /* Reassembly buffer: server frames are single-line JSON < 512B, but the
     * transport may split them into chunks. */
    static char rx[1024];

    switch (event_id) {
    case WEBSOCKET_EVENT_CONNECTED: {
        ESP_LOGI(TAG, "ws connected");
        s_ws_connected = true;
        s_ws_down_since_tick = 0;
        char hello[160];
        snprintf(hello, sizeof(hello),
                 "{\"t\":\"hello\",\"proto\":1,\"id\":\"%s\",\"board\":\"%s\",\"fw\":\"%s\"}",
                 s_device_id, board_id(), esp_app_get_description()->version);
        esp_websocket_client_send_text(s_ws, hello, strlen(hello), pdMS_TO_TICKS(2000));
        break;
    }
    case WEBSOCKET_EVENT_DISCONNECTED:
    case WEBSOCKET_EVENT_ERROR:
        if (s_ws_connected || s_ws_down_since_tick == 0) {
            ESP_LOGW(TAG, "ws disconnected");
            s_ws_down_since_tick = xTaskGetTickCount();
        }
        s_ws_connected = false;
        break;
    case WEBSOCKET_EVENT_DATA:
        if (data->op_code != 0x1 && data->op_code != 0x0) break; /* text/cont only */
        if (data->payload_len <= 0 || data->payload_len >= (int)sizeof(rx)) break;
        memcpy(rx + data->payload_offset, data->data_ptr, data->data_len);
        if (data->payload_offset + data->data_len >= data->payload_len) {
            rx[data->payload_len] = '\0';
            ws_handle_text(rx);
        }
        break;
    default:
        break;
    }
}

static void ws_start(void)
{
    if (s_ws) {
        esp_websocket_client_destroy(s_ws);
        s_ws = NULL;
    }
    char uri[256];
    snprintf(uri, sizeof(uri), "%s/device?token=%s&id=%s&board=%s&fw=%s",
             s_cfg.url, s_cfg.token, s_device_id, board_id(),
             esp_app_get_description()->version);

    esp_websocket_client_config_t cfg = {
        .uri = uri,
        .reconnect_timeout_ms = 5000,
        .network_timeout_ms = 5000,
        .ping_interval_sec = 10,
        .buffer_size = 2048,
        .task_stack = 6144,
    };
    s_ws = esp_websocket_client_init(&cfg);
    if (!s_ws) {
        ESP_LOGE(TAG, "ws client init failed");
        return;
    }
    esp_websocket_register_events(s_ws, WEBSOCKET_EVENT_ANY, ws_event_handler, NULL);
    esp_websocket_client_start(s_ws);
    s_ws_down_since_tick = xTaskGetTickCount();
    ESP_LOGI(TAG, "ws connecting: %s", s_cfg.url);
}

/* --------------------------------------------------------------------- mDNS */

/* The Mac's IP changed (DHCP/network move): find _agentshud._tcp again,
 * preferring the host we were provisioned against. */
static bool mdns_rediscover(void)
{
    mdns_result_t *results = NULL;
    if (mdns_query_ptr("_agentshud", "_tcp", 3000, 8, &results) != ESP_OK || !results) {
        return false;
    }
    mdns_result_t *best = NULL;
    for (mdns_result_t *r = results; r; r = r->next) {
        if (!r->addr) continue;
        bool name_match = false;
        for (size_t i = 0; i < r->txt_count; i++) {
            if (strcmp(r->txt[i].key, "name") == 0 && r->txt[i].value &&
                s_cfg.name[0] && strcmp(r->txt[i].value, s_cfg.name) == 0) {
                name_match = true;
                break;
            }
        }
        if (name_match) { best = r; break; }
        if (!best) best = r;
    }
    bool updated = false;
    if (best && best->addr && best->addr->addr.type == ESP_IPADDR_TYPE_V4) {
        char url[128];
        snprintf(url, sizeof(url), "ws://" IPSTR ":%u",
                 IP2STR(&best->addr->addr.u_addr.ip4), best->port);
        if (strcmp(url, s_cfg.url) != 0) {
            ESP_LOGI(TAG, "mdns found server at %s (was %s)", url, s_cfg.url);
            strlcpy(s_cfg.url, url, sizeof(s_cfg.url));
            net_cfg_save_url(url);
            updated = true;
        }
    }
    mdns_query_results_free(results);
    return updated;
}

/* --------------------------------------------------------------------- WiFi */

static bool is_auth_fail(int reason)
{
    switch (reason) {
    case WIFI_REASON_AUTH_EXPIRE:
    case WIFI_REASON_AUTH_FAIL:
    case WIFI_REASON_NOT_AUTHED:
    case WIFI_REASON_4WAY_HANDSHAKE_TIMEOUT:
    case WIFI_REASON_HANDSHAKE_TIMEOUT:
        return true;
    default:
        return false;
    }
}

static void wifi_event_handler(void *arg, esp_event_base_t base,
                               int32_t event_id, void *event_data)
{
    if (base == WIFI_EVENT && event_id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && event_id == WIFI_EVENT_STA_DISCONNECTED) {
        wifi_event_sta_disconnected_t *d = event_data;
        s_wifi_up = false;
        s_last_disc_reason = d->reason;
        if (is_auth_fail(d->reason)) s_auth_fails++;
        else s_auth_fails = 0;
        ESP_LOGW(TAG, "wifi disconnected (reason %d, auth fails %d)", d->reason, s_auth_fails);
        xEventGroupSetBits(s_events, EV_WIFI_FAIL);
    } else if (base == IP_EVENT && event_id == IP_EVENT_STA_GOT_IP) {
        ip_event_got_ip_t *e = event_data;
        s_wifi_up = true;
        s_auth_fails = 0;
        ESP_LOGI(TAG, "got ip: " IPSTR, IP2STR(&e->ip_info.ip));
        xEventGroupSetBits(s_events, EV_GOT_IP);
    }
}

static void wifi_connect_with_cfg(void)
{
    wifi_config_t wc = {0};
    strlcpy((char *)wc.sta.ssid, s_cfg.ssid, sizeof(wc.sta.ssid));
    strlcpy((char *)wc.sta.password, s_cfg.pw, sizeof(wc.sta.password));
    wc.sta.scan_method = WIFI_ALL_CHANNEL_SCAN;
    wc.sta.sort_method = WIFI_CONNECT_AP_BY_SIGNAL;
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    esp_err_t err = esp_wifi_start(); /* STA_START handler calls connect */
    if (err == ESP_ERR_WIFI_NOT_INIT) {
        ESP_LOGE(TAG, "wifi not initialized");
    } else if (err != ESP_OK && err != ESP_ERR_WIFI_CONN) {
        ESP_LOGW(TAG, "esp_wifi_start: %s", esp_err_to_name(err));
    }
    esp_wifi_connect();
}

/* ------------------------------------------------------------- provisioning */

/* Runs in the NimBLE host task: stash the request and wake the net task. */
static void on_provision_request(const net_cfg_t *cfg)
{
    s_pending_cfg = *cfg;
    xEventGroupSetBits(s_events, EV_PROV_REQUEST);
}

/* ----------------------------------------------------------------- net task */

static void net_task(void *arg)
{
    bool ws_started = false;

    if (!s_have_cfg) {
        s_provisioning = true;
        provision_ble_start(on_provision_request);
        s_on_update(NULL, AHUD_NET_PROVISIONING);
    } else {
        s_on_update(NULL, AHUD_NET_WIFI_CONNECTING);
        wifi_connect_with_cfg();
    }

    while (true) {
        EventBits_t bits = xEventGroupWaitBits(
            s_events, EV_GOT_IP | EV_WIFI_FAIL | EV_PROV_REQUEST,
            pdTRUE, pdFALSE, pdMS_TO_TICKS(1000));

        uint32_t now = xTaskGetTickCount();

        if (bits & EV_PROV_REQUEST) {
            /* New credentials over BLE: persist, then (re)try WiFi live so the
             * provisioner sees connecting/got_ip/ws_ok or a failure code. */
            s_cfg = s_pending_cfg;
            s_have_cfg = true;
            net_cfg_save(&s_cfg);
            s_auth_fails = 0;
            s_prov_ok_tick = 0;
            provision_ble_set_status("connecting", NULL);
            s_on_update(NULL, AHUD_NET_WIFI_CONNECTING);
            if (ws_started && s_ws) {
                esp_websocket_client_stop(s_ws);
                ws_started = false;
            }
            esp_wifi_disconnect();
            wifi_connect_with_cfg();
        }

        if (bits & EV_GOT_IP) {
            esp_netif_ip_info_t ip_info;
            esp_netif_t *sta = esp_netif_get_handle_from_ifkey("WIFI_STA_DEF");
            char ip[20] = "";
            if (sta && esp_netif_get_ip_info(sta, &ip_info) == ESP_OK) {
                snprintf(ip, sizeof(ip), IPSTR, IP2STR(&ip_info.ip));
            }
            if (s_provisioning) provision_ble_set_status("got_ip", ip);
            ws_start();
            ws_started = true;
        }

        if (bits & EV_WIFI_FAIL) {
            if (s_provisioning) {
                provision_ble_set_status(
                    s_last_disc_reason == WIFI_REASON_NO_AP_FOUND ? "ap_not_found"
                    : is_auth_fail(s_last_disc_reason)            ? "bad_pass"
                                                                  : "connecting",
                    NULL);
            }
            if (s_have_cfg && s_auth_fails >= MAX_AUTH_FAILS && !s_provisioning) {
                /* Password almost certainly changed: reopen pairing while we
                 * keep retrying in the background. */
                ESP_LOGW(TAG, "repeated auth failures -> pairing mode");
                s_provisioning = true;
                s_prov_ok_tick = 0;
                provision_ble_start(on_provision_request);
                s_on_update(NULL, AHUD_NET_PROVISIONING);
            }
            if (s_have_cfg) {
                vTaskDelay(pdMS_TO_TICKS(3000));
                esp_wifi_connect();
            }
        }

        /* Provisioning finished: give the Mac a moment to read ws_ok, then
         * shut BLE down and release its RAM. */
        if (s_provisioning && s_prov_ok_tick != 0 &&
            (now - s_prov_ok_tick) * portTICK_PERIOD_MS > PROV_LINGER_MS) {
            s_provisioning = false;
            provision_ble_stop();
        }

        /* Server moved? Ask mDNS once the WS has been down for a while. */
        if (ws_started && !s_ws_connected && s_wifi_up && s_ws_down_since_tick != 0 &&
            (now - s_ws_down_since_tick) * portTICK_PERIOD_MS > REDISCOVER_MS) {
            s_ws_down_since_tick = now; /* rate-limit the queries */
            if (mdns_rediscover()) {
                ws_start();
            }
        }

        /* UI state when we have no fresh data to show. */
        if (s_provisioning && !s_have_cfg) {
            s_on_update(NULL, AHUD_NET_PROVISIONING);
        } else if (!s_wifi_up) {
            if (s_have_cfg) s_on_update(NULL, AHUD_NET_WIFI_CONNECTING);
        } else if (!s_ws_connected) {
            s_on_update(NULL, AHUD_NET_SERVER_UNREACHABLE);
        } else {
            uint32_t age = (now - s_last_data_tick) * portTICK_PERIOD_MS;
            if (age > STALE_MS) s_on_update(NULL, AHUD_NET_SERVER_UNREACHABLE);
        }
    }
}

void net_start(ahud_update_cb_t on_update)
{
    s_on_update = on_update;
    s_last_data_tick = xTaskGetTickCount();
    s_events = xEventGroupCreate();

    /* Device id from the WiFi MAC (stable, radio-independent). Same format as
     * the old BLE id: last two bytes, upper-case hex. */
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_WIFI_STA);
    snprintf(s_device_id, sizeof(s_device_id), "%02X%02X", mac[4], mac[5]);

    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());
    esp_netif_create_default_wifi_sta();
    wifi_init_config_t wcfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&wcfg));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                               wifi_event_handler, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                               wifi_event_handler, NULL));

    /* mDNS responder+resolver: lets the dial find a moved server. */
    if (mdns_init() == ESP_OK) {
        char host[24];
        snprintf(host, sizeof(host), "agentshud-%s", s_device_id);
        mdns_hostname_set(host);
    }

    s_have_cfg = net_cfg_load(&s_cfg);
    ESP_LOGI(TAG, "net start: id=%s provisioned=%d fw=%s board=%s",
             s_device_id, (int)s_have_cfg,
             esp_app_get_description()->version, board_id());

    xTaskCreate(net_task, "ahud_net", 6144, NULL, 4, NULL);
}
