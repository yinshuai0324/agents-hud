#include "net_cfg.h"

#include <string.h>

#include "nvs.h"
#include "esp_log.h"

static const char *TAG = "ahud_cfg";
#define NS "ahud"

static bool get_str(nvs_handle_t h, const char *key, char *out, size_t cap)
{
    size_t len = cap;
    return nvs_get_str(h, key, out, &len) == ESP_OK;
}

bool net_cfg_load(net_cfg_t *out)
{
    memset(out, 0, sizeof(*out));
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READONLY, &h) != ESP_OK) return false;
    bool ok = get_str(h, "ssid", out->ssid, sizeof(out->ssid))
           && get_str(h, "url", out->url, sizeof(out->url));
    /* pw/token/name may legitimately be empty. */
    get_str(h, "pw", out->pw, sizeof(out->pw));
    get_str(h, "token", out->token, sizeof(out->token));
    get_str(h, "name", out->name, sizeof(out->name));
    nvs_close(h);
    return ok && out->ssid[0] != '\0' && out->url[0] != '\0';
}

bool net_cfg_save(const net_cfg_t *cfg)
{
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) return false;
    bool ok = nvs_set_str(h, "ssid", cfg->ssid) == ESP_OK
           && nvs_set_str(h, "pw", cfg->pw) == ESP_OK
           && nvs_set_str(h, "url", cfg->url) == ESP_OK
           && nvs_set_str(h, "token", cfg->token) == ESP_OK
           && nvs_set_str(h, "name", cfg->name) == ESP_OK;
    ok = ok && nvs_commit(h) == ESP_OK;
    nvs_close(h);
    ESP_LOGI(TAG, "provisioning %s (ssid=%s url=%s)", ok ? "saved" : "SAVE FAILED",
             cfg->ssid, cfg->url);
    return ok;
}

void net_cfg_save_url(const char *url)
{
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) return;
    if (nvs_set_str(h, "url", url) == ESP_OK) nvs_commit(h);
    nvs_close(h);
    ESP_LOGI(TAG, "server url updated: %s", url);
}

void net_cfg_save_rotation(uint8_t rotation)
{
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) return;
    if (nvs_set_u8(h, "rot", rotation % 4) == ESP_OK) nvs_commit(h);
    nvs_close(h);
}

void net_cfg_erase(void)
{
    nvs_handle_t h;
    if (nvs_open(NS, NVS_READWRITE, &h) != ESP_OK) return;
    /* Erase provisioning keys only — "rot" (display rotation) survives. */
    nvs_erase_key(h, "ssid");
    nvs_erase_key(h, "pw");
    nvs_erase_key(h, "url");
    nvs_erase_key(h, "token");
    nvs_erase_key(h, "name");
    nvs_commit(h);
    nvs_close(h);
    ESP_LOGW(TAG, "provisioning erased");
}
