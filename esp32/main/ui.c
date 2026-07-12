#include "ui.h"

#include <stdio.h>
#include <string.h>

#include "lvgl.h"
#include "esp_heap_caps.h"
#include "logo.h"
#include "net.h"
#include "splash_animations.h"

LV_FONT_DECLARE(font_cn_20);

/* Anthropic-inspired palette (borrowed from Clawdmeter's theme). */
#define COL_BG     lv_color_hex(0x000000)
#define COL_PANEL  lv_color_hex(0x1f1f1e)
#define COL_TEXT   lv_color_hex(0xfaf9f5)
#define COL_DIM    lv_color_hex(0xb0aea5)
#define COL_ACCENT lv_color_hex(0xd97757)
#define COL_GREEN  lv_color_hex(0x788c5d)
#define COL_RED    lv_color_hex(0xc0392b)
#define COL_BAR_BG lv_color_hex(0x2a2a28)

#define CARD_W 340
#define CARD_H 116

/* 红绿灯 state colors — keep in sync with android CCColors. */
#define COL_ST_ERROR   lv_color_hex(0xFF453A)
#define COL_ST_NOTIFY  lv_color_hex(0xFF9F0A)
#define COL_ST_WAITING lv_color_hex(0x3B9EFF)
#define COL_ST_WORKING lv_color_hex(0xFFC42E)
#define COL_ST_QUIET   lv_color_hex(0x34C759)

typedef struct {
    lv_obj_t *card;
    lv_obj_t *pct;
    lv_obj_t *bar;
    lv_obj_t *resets;
} usage_card_t;

static lv_obj_t *s_view_usage;
static lv_obj_t *s_state_ring;
static lv_obj_t *s_view_clawd;
static lv_obj_t *s_view_detail;
static lv_obj_t *s_logo;
static lv_image_dsc_t s_logo_dsc;
static usage_card_t s_card_5h;
static usage_card_t s_card_7d;
static lv_obj_t *s_status_row;
static lv_obj_t *s_status_spinner;
static lv_obj_t *s_status_lbl;

/* Detail view */
static lv_obj_t *s_det_sessions;
static lv_obj_t *s_det_id;
static lv_obj_t *s_det_today;
static lv_obj_t *s_det_burn;
static lv_obj_t *s_det_model;
static lv_obj_t *s_det_plan;

static ahud_snapshot_t s_last;
static bool s_have_data;
static ahud_net_state_t s_net = AHUD_NET_WIFI_CONNECTING;
static uint32_t s_word_ms;
static int s_word_idx;

/* Rotating gerunds shown while Claude is working (Clawdmeter tradition). */
static const char *const WORK_WORDS[] = {
    "思考中", "炼丹中", "搬砖中", "施法中",
    "挠头中", "熬夜中", "打磨中", "冒泡中",
    "编织中", "酝酿中", "翻箱倒柜中", "奋笔疾书中",
};
#define WORK_WORD_COUNT (sizeof(WORK_WORDS) / sizeof(WORK_WORDS[0]))

static lv_color_t pct_color(int pct)
{
    if (pct >= 80) return COL_RED;
    if (pct >= 50) return COL_ACCENT;
    return COL_GREEN;
}

static void fmt_tokens(long long v, char *out, size_t cap)
{
    if (v >= 1000000000LL) snprintf(out, cap, "%.1fB", v / 1e9);
    else if (v >= 1000000LL) snprintf(out, cap, "%.1fM", v / 1e6);
    else if (v >= 1000LL) snprintf(out, cap, "%.1fk", v / 1e3);
    else snprintf(out, cap, "%lld", v);
}

static void fmt_reset(int mins, char *out, size_t cap)
{
    if (mins <= 0) snprintf(out, cap, "--");
    else if (mins < 60) snprintf(out, cap, "%d分钟后重置", mins);
    else if (mins < 1440) snprintf(out, cap, "%d小时%d分后重置", mins / 60, mins % 60);
    else snprintf(out, cap, "%d天%d小时后重置", mins / 1440, (mins % 1440) / 60);
}

/* ================== Clawd pixel-pet animation (from Clawdmeter) ========== */

#define CLAWD_GRID 20

static lv_obj_t *s_clawd_canvas;
static uint16_t *s_clawd_buf;
static uint16_t *s_clawd_row;
static int s_clawd_cell;
static int s_clawd_w;
static uint16_t s_anim_idx;
static uint16_t s_frame_idx;
static uint32_t s_frame_ms;
static uint32_t s_pick_ms;

/* Auto-rotate to the next animation of the active group every 20 s. */
#define CLAWD_ROTATE_MS 20000

/* Usage-rate groups: idle/sleepy, normal, active, heavy (dance party). */
#define CLAWD_GROUPS 4
#define CLAWD_GROUP_MAX 4
static const char *const CLAWD_GROUP_NAMES[CLAWD_GROUPS][CLAWD_GROUP_MAX] = {
    { "expression sleep", "idle breathe", "idle blink", "expression wink" },
    { "idle look around", "work think", "work coding", NULL },
    { "dance sway", "expression surprise", "dance bounce", NULL },
    { "dance bounce dj", "dance sway dj", "dance djmix", NULL },
};
static int8_t s_group_lists[CLAWD_GROUPS][CLAWD_GROUP_MAX];
static uint8_t s_group_size[CLAWD_GROUPS];
static uint8_t s_group_rot[CLAWD_GROUPS];

static void clawd_resolve_groups(void)
{
    for (int g = 0; g < CLAWD_GROUPS; g++) {
        s_group_size[g] = 0;
        for (int s = 0; s < CLAWD_GROUP_MAX; s++) {
            const char *want = CLAWD_GROUP_NAMES[g][s];
            if (!want) continue;
            for (int i = 0; i < SPLASH_ANIM_COUNT; i++) {
                if (strcmp(splash_anims[i].name, want) == 0) {
                    s_group_lists[g][s_group_size[g]++] = (int8_t)i;
                    break;
                }
            }
        }
    }
}

static int clawd_group(void)
{
    if (!s_have_data || s_last.s_working == 0) return 0;
    long long rate = s_last.u5h_burn_per_min;
    if (rate < 5000) return 1;
    if (rate < 20000) return 2;
    return 3;
}

static void clawd_render(void)
{
    if (!s_clawd_buf || !s_clawd_row) return;
    const splash_anim_def_t *a = &splash_anims[s_anim_idx];
    const uint8_t *cells = a->frames[s_frame_idx];
    for (int gy = 0; gy < CLAWD_GRID; gy++) {
        for (int gx = 0; gx < CLAWD_GRID; gx++) {
            uint8_t code = cells[gy * CLAWD_GRID + gx];
            uint16_t color = (code < SPLASH_PALETTE_SIZE) ? a->palette[code] : 0x0000;
            uint16_t *p = &s_clawd_row[gx * s_clawd_cell];
            for (int i = 0; i < s_clawd_cell; i++) p[i] = color;
        }
        for (int dy = 0; dy < s_clawd_cell; dy++) {
            memcpy(&s_clawd_buf[(gy * s_clawd_cell + dy) * s_clawd_w], s_clawd_row, s_clawd_w * 2);
        }
    }
    if (s_clawd_canvas) lv_obj_invalidate(s_clawd_canvas);
}

static void clawd_pick(void)
{
    int g = clawd_group();
    if (s_group_size[g] == 0) return;
    uint8_t slot = s_group_rot[g] % s_group_size[g];
    s_group_rot[g]++;
    s_anim_idx = (uint16_t)s_group_lists[g][slot];
    s_frame_idx = 0;
    s_frame_ms = lv_tick_get();
    s_pick_ms = s_frame_ms;
    clawd_render();
}

static void clawd_timer_cb(lv_timer_t *t)
{
    (void)t;
    if (!s_view_clawd || lv_obj_has_flag(s_view_clawd, LV_OBJ_FLAG_HIDDEN)) return;
    if (!s_clawd_buf || SPLASH_ANIM_COUNT == 0) return;

    uint32_t now = lv_tick_get();
    if (now - s_pick_ms >= CLAWD_ROTATE_MS) {
        clawd_pick();
        return;
    }
    const splash_anim_def_t *a = &splash_anims[s_anim_idx];
    if (a->frame_count == 0) return;
    if (now - s_frame_ms >= a->holds[s_frame_idx]) {
        s_frame_idx = (s_frame_idx + 1) % a->frame_count;
        s_frame_ms = now;
        clawd_render();
    }
}

/* ========================================================================== */

static void view_toggle_cb(lv_event_t *e)
{
    (void)e;
    /* Cycle: usage -> clawd -> detail -> usage */
    if (!lv_obj_has_flag(s_view_usage, LV_OBJ_FLAG_HIDDEN)) {
        lv_obj_add_flag(s_view_usage, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(s_view_clawd, LV_OBJ_FLAG_HIDDEN);
        clawd_pick();
    } else if (!lv_obj_has_flag(s_view_clawd, LV_OBJ_FLAG_HIDDEN)) {
        lv_obj_add_flag(s_view_clawd, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(s_view_detail, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(s_view_detail, LV_OBJ_FLAG_HIDDEN);
        lv_obj_remove_flag(s_view_usage, LV_OBJ_FLAG_HIDDEN);
    }
}

static lv_obj_t *make_view(lv_obj_t *scr)
{
    lv_obj_t *v = lv_obj_create(scr);
    lv_obj_remove_style_all(v);
    lv_obj_set_size(v, LV_PCT(100), LV_PCT(100));
    lv_obj_add_flag(v, LV_OBJ_FLAG_EVENT_BUBBLE);
    lv_obj_add_flag(v, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_remove_flag(v, LV_OBJ_FLAG_SCROLLABLE);
    return v;
}

static lv_obj_t *make_label(lv_obj_t *parent, const lv_font_t *font, lv_color_t color)
{
    lv_obj_t *lbl = lv_label_create(parent);
    lv_obj_set_style_text_font(lbl, font, 0);
    lv_obj_set_style_text_color(lbl, color, 0);
    lv_label_set_text(lbl, "");
    lv_obj_add_flag(lbl, LV_OBJ_FLAG_EVENT_BUBBLE);
    return lbl;
}

static lv_obj_t *make_pill(lv_obj_t *parent, const char *text)
{
    lv_obj_t *lbl = make_label(parent, &font_cn_20, COL_TEXT);
    lv_label_set_text(lbl, text);
    lv_obj_set_style_bg_color(lbl, COL_BAR_BG, 0);
    lv_obj_set_style_bg_opa(lbl, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(lbl, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_pad_hor(lbl, 14, 0);
    lv_obj_set_style_pad_ver(lbl, 5, 0);
    return lbl;
}

static void make_usage_card(lv_obj_t *parent, usage_card_t *c, const char *tag, int y)
{
    c->card = lv_obj_create(parent);
    lv_obj_set_size(c->card, CARD_W, CARD_H);
    lv_obj_align(c->card, LV_ALIGN_TOP_MID, 0, y);
    lv_obj_set_style_bg_color(c->card, COL_PANEL, 0);
    lv_obj_set_style_bg_opa(c->card, LV_OPA_COVER, 0);
    lv_obj_set_style_radius(c->card, 18, 0);
    lv_obj_set_style_border_width(c->card, 0, 0);
    lv_obj_set_style_pad_hor(c->card, 18, 0);
    lv_obj_set_style_pad_ver(c->card, 10, 0);
    lv_obj_remove_flag(c->card, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(c->card, LV_OBJ_FLAG_EVENT_BUBBLE);

    c->pct = make_label(c->card, &lv_font_montserrat_48, COL_TEXT);
    lv_obj_align(c->pct, LV_ALIGN_TOP_LEFT, 0, -4);
    lv_label_set_text(c->pct, "--");

    lv_obj_t *pill = make_pill(c->card, tag);
    lv_obj_align(pill, LV_ALIGN_TOP_RIGHT, 0, 4);

    c->bar = lv_bar_create(c->card);
    lv_obj_set_size(c->bar, CARD_W - 36, 12);
    lv_obj_align(c->bar, LV_ALIGN_TOP_MID, 0, 52);
    lv_bar_set_range(c->bar, 0, 100);
    lv_bar_set_value(c->bar, 0, LV_ANIM_OFF);
    lv_obj_set_style_bg_color(c->bar, COL_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_bg_opa(c->bar, LV_OPA_COVER, LV_PART_MAIN);
    lv_obj_set_style_radius(c->bar, 6, LV_PART_MAIN);
    lv_obj_set_style_bg_color(c->bar, COL_GREEN, LV_PART_INDICATOR);
    lv_obj_set_style_bg_opa(c->bar, LV_OPA_COVER, LV_PART_INDICATOR);
    lv_obj_set_style_radius(c->bar, 6, LV_PART_INDICATOR);
    lv_obj_add_flag(c->bar, LV_OBJ_FLAG_EVENT_BUBBLE);

    c->resets = make_label(c->card, &font_cn_20, COL_DIM);
    lv_obj_align(c->resets, LV_ALIGN_TOP_LEFT, 0, 70);
    lv_label_set_text(c->resets, "---");
}

static lv_obj_t *make_detail_row(lv_obj_t *parent, const char *name, int y)
{
    lv_obj_t *k = make_label(parent, &font_cn_20, COL_DIM);
    lv_label_set_text(k, name);
    lv_obj_align(k, LV_ALIGN_TOP_MID, -80, y);
    lv_obj_t *v = make_label(parent, &lv_font_montserrat_20, COL_TEXT);
    lv_obj_align(v, LV_ALIGN_TOP_MID, 60, y - 2);
    return v;
}

static lv_color_t dominant_color(const char *state)
{
    if (strcmp(state, "error") == 0) return COL_ST_ERROR;
    if (strcmp(state, "notify") == 0) return COL_ST_NOTIFY;
    if (strcmp(state, "waiting") == 0) return COL_ST_WAITING;
    if (strcmp(state, "working") == 0) return COL_ST_WORKING;
    if (strcmp(state, "quiet") == 0) return COL_ST_QUIET;
    return COL_BAR_BG;
}

static void refresh_ring(void)
{
    lv_color_t c = (s_net == AHUD_NET_OK && s_have_data)
        ? dominant_color(s_last.dominant)
        : COL_BAR_BG; /* offline/waiting: dim neutral ring */
    lv_obj_set_style_border_color(s_state_ring, c, 0);
}

static void refresh_status(void)
{
    bool spin = false;
    char buf[48];
    lv_color_t color = COL_DIM;

    if (net_device_id()[0]) {
        lv_label_set_text(s_det_id, net_device_id());
    }

    switch (s_net) {
    case AHUD_NET_WIFI_CONNECTING:
        if (net_device_id()[0]) {
            snprintf(buf, sizeof(buf), "等待蓝牙连接 · %s", net_device_id());
        } else {
            snprintf(buf, sizeof(buf), "等待蓝牙连接…");
        }
        color = COL_ACCENT;
        break;
    case AHUD_NET_SERVER_UNREACHABLE:
        snprintf(buf, sizeof(buf), "数据超时");
        color = COL_RED;
        break;
    default:
        if (!s_have_data) {
            snprintf(buf, sizeof(buf), "...");
        } else if (s_last.s_working > 0) {
            spin = true;
            color = COL_ACCENT;
            if (s_last.s_working > 1) {
                snprintf(buf, sizeof(buf), "%s… ×%d", WORK_WORDS[s_word_idx], s_last.s_working);
            } else {
                snprintf(buf, sizeof(buf), "%s…", WORK_WORDS[s_word_idx]);
            }
        } else if (s_last.s_notify > 0 || s_last.s_waiting > 0) {
            color = COL_ACCENT;
            snprintf(buf, sizeof(buf), "等你回复 ×%d", s_last.s_notify + s_last.s_waiting);
        } else {
            snprintf(buf, sizeof(buf), "空闲");
        }
        break;
    }

    refresh_ring();
    lv_label_set_text(s_status_lbl, buf);
    lv_obj_set_style_text_color(s_status_lbl, color, 0);
    if (spin) {
        lv_obj_remove_flag(s_status_spinner, LV_OBJ_FLAG_HIDDEN);
    } else {
        lv_obj_add_flag(s_status_spinner, LV_OBJ_FLAG_HIDDEN);
    }
    /* Re-center the row contents. */
    lv_obj_update_layout(s_status_row);
}

static void word_timer_cb(lv_timer_t *t)
{
    (void)t;
    uint32_t now = lv_tick_get();
    if (now - s_word_ms >= 4000) {
        s_word_ms = now;
        s_word_idx = (s_word_idx + 7) % WORK_WORD_COUNT;
        if (s_have_data && s_last.s_working > 0 && s_net == AHUD_NET_OK) {
            refresh_status();
        }
    }
}

void ui_init(void)
{
    lv_obj_t *scr = lv_screen_active();
    lv_obj_set_style_bg_color(scr, COL_BG, 0);
    lv_obj_set_style_bg_opa(scr, LV_OPA_COVER, 0);
    lv_obj_add_event_cb(scr, view_toggle_cb, LV_EVENT_CLICKED, NULL);

    /* ---- Usage view (default) ---- */
    s_view_usage = make_view(scr);

    /* Outermost ring: dominant session state color (the traffic light). */
    s_state_ring = lv_obj_create(s_view_usage);
    lv_obj_remove_style_all(s_state_ring);
    lv_obj_set_size(s_state_ring, 466, 466);
    lv_obj_center(s_state_ring);
    lv_obj_set_style_radius(s_state_ring, LV_RADIUS_CIRCLE, 0);
    lv_obj_set_style_border_width(s_state_ring, 10, 0);
    lv_obj_set_style_border_color(s_state_ring, COL_BAR_BG, 0);
    lv_obj_set_style_border_opa(s_state_ring, LV_OPA_COVER, 0);
    lv_obj_add_flag(s_state_ring, LV_OBJ_FLAG_EVENT_BUBBLE);

    s_logo_dsc.header.w = LOGO_WIDTH;
    s_logo_dsc.header.h = LOGO_HEIGHT;
    s_logo_dsc.header.cf = LV_COLOR_FORMAT_RGB565A8;
    s_logo_dsc.header.stride = LOGO_WIDTH * 2;
    s_logo_dsc.data = logo_data;
    s_logo_dsc.data_size = LOGO_WIDTH * LOGO_HEIGHT * 3;

    s_logo = lv_image_create(s_view_usage);
    lv_image_set_src(s_logo, &s_logo_dsc);
    lv_obj_align(s_logo, LV_ALIGN_TOP_MID, 0, 26);
    lv_obj_add_flag(s_logo, LV_OBJ_FLAG_EVENT_BUBBLE);

    make_usage_card(s_view_usage, &s_card_5h, "5小时", 124);
    make_usage_card(s_view_usage, &s_card_7d, "7天", 252);

    s_status_row = lv_obj_create(s_view_usage);
    lv_obj_remove_style_all(s_status_row);
    lv_obj_set_size(s_status_row, LV_SIZE_CONTENT, 30);
    lv_obj_align(s_status_row, LV_ALIGN_TOP_MID, 0, 384);
    lv_obj_set_flex_flow(s_status_row, LV_FLEX_FLOW_ROW);
    lv_obj_set_flex_align(s_status_row, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER, LV_FLEX_ALIGN_CENTER);
    lv_obj_set_style_pad_column(s_status_row, 8, 0);
    lv_obj_add_flag(s_status_row, LV_OBJ_FLAG_EVENT_BUBBLE);

    s_status_spinner = lv_spinner_create(s_status_row);
    lv_obj_set_size(s_status_spinner, 22, 22);
    lv_spinner_set_anim_params(s_status_spinner, 1200, 200);
    lv_obj_set_style_arc_width(s_status_spinner, 3, LV_PART_MAIN);
    lv_obj_set_style_arc_width(s_status_spinner, 3, LV_PART_INDICATOR);
    lv_obj_set_style_arc_color(s_status_spinner, COL_BAR_BG, LV_PART_MAIN);
    lv_obj_set_style_arc_color(s_status_spinner, COL_ACCENT, LV_PART_INDICATOR);
    lv_obj_add_flag(s_status_spinner, LV_OBJ_FLAG_HIDDEN);

    s_status_lbl = make_label(s_status_row, &font_cn_20, COL_ACCENT);
    lv_label_set_text(s_status_lbl, "等待蓝牙连接…");

    /* ---- Clawd pet view ---- */
    s_view_clawd = make_view(scr);
    lv_obj_add_flag(s_view_clawd, LV_OBJ_FLAG_HIDDEN);

    clawd_resolve_groups();
    s_clawd_cell = 466 / CLAWD_GRID; /* 23 -> 460x460 canvas */
    s_clawd_w = CLAWD_GRID * s_clawd_cell;
    s_clawd_buf = heap_caps_malloc(s_clawd_w * s_clawd_w * 2, MALLOC_CAP_SPIRAM);
    s_clawd_row = heap_caps_malloc(s_clawd_w * 2, MALLOC_CAP_SPIRAM);
    if (s_clawd_buf && s_clawd_row) {
        s_clawd_canvas = lv_canvas_create(s_view_clawd);
        lv_canvas_set_buffer(s_clawd_canvas, s_clawd_buf, s_clawd_w, s_clawd_w, LV_COLOR_FORMAT_RGB565);
        lv_obj_center(s_clawd_canvas);
        lv_obj_add_flag(s_clawd_canvas, LV_OBJ_FLAG_EVENT_BUBBLE);
        clawd_pick();
        lv_timer_create(clawd_timer_cb, 40, NULL);
    }

    /* ---- Detail view (tap to toggle) ---- */
    s_view_detail = make_view(scr);
    lv_obj_add_flag(s_view_detail, LV_OBJ_FLAG_HIDDEN);

    lv_obj_t *dlogo = lv_image_create(s_view_detail);
    lv_image_set_src(dlogo, &s_logo_dsc);
    lv_image_set_scale(dlogo, 160); /* 80px -> 50px */
    lv_obj_align(dlogo, LV_ALIGN_TOP_MID, 0, 30);
    lv_obj_add_flag(dlogo, LV_OBJ_FLAG_EVENT_BUBBLE);

    s_det_sessions = make_label(s_view_detail, &font_cn_20, COL_TEXT);
    lv_obj_align(s_det_sessions, LV_ALIGN_TOP_MID, 0, 118);
    lv_label_set_text(s_det_sessions, "--");

    s_det_today = make_detail_row(s_view_detail, "今日", 168);
    s_det_burn = make_detail_row(s_view_detail, "速率", 210);
    s_det_model = make_detail_row(s_view_detail, "模型", 252);
    s_det_plan = make_detail_row(s_view_detail, "套餐", 294);

    s_det_id = make_detail_row(s_view_detail, "编号", 336);
    lv_label_set_text(s_det_id, "--");

    lv_obj_t *hint = make_label(s_view_detail, &font_cn_20, COL_DIM);
    lv_label_set_text(hint, "点一下返回");
    lv_obj_align(hint, LV_ALIGN_TOP_MID, 0, 388);

    lv_timer_create(word_timer_cb, 500, NULL);
    s_word_ms = lv_tick_get();
}

static void update_card(usage_card_t *c, int percent, int reset_min, bool known)
{
    char buf[32];
    if (!known) {
        lv_label_set_text(c->pct, "--");
        lv_bar_set_value(c->bar, 0, LV_ANIM_OFF);
        lv_label_set_text(c->resets, "---");
        return;
    }
    snprintf(buf, sizeof(buf), "%d%%", percent);
    lv_label_set_text(c->pct, buf);
    lv_bar_set_value(c->bar, percent > 100 ? 100 : percent, LV_ANIM_ON);
    lv_obj_set_style_bg_color(c->bar, pct_color(percent), LV_PART_INDICATOR);
    fmt_reset(reset_min, buf, sizeof(buf));
    lv_label_set_text(c->resets, buf);
}

void ui_update(const ahud_snapshot_t *snap, ahud_net_state_t net)
{
    s_net = net;

    if (snap) {
        s_last = *snap;
        s_have_data = true;
        char tok[16], buf[64];

        update_card(&s_card_5h, snap->u5h_percent, snap->u5h_reset_min, true);
        update_card(&s_card_7d, snap->u7d_percent, snap->u7d_reset_min, snap->u7d_percent >= 0);

        snprintf(buf, sizeof(buf), "%d 个会话 · %d 个在忙", snap->s_total, snap->s_working);
        lv_label_set_text(s_det_sessions, buf);

        fmt_tokens(snap->today_tokens, tok, sizeof(tok));
        snprintf(buf, sizeof(buf), "%s tok", tok);
        lv_label_set_text(s_det_today, buf);

        fmt_tokens(snap->u5h_burn_per_min, tok, sizeof(tok));
        snprintf(buf, sizeof(buf), "%s/min", tok);
        lv_label_set_text(s_det_burn, buf);

        lv_label_set_text(s_det_model, snap->model[0] ? snap->model : "--");
        lv_label_set_text(s_det_plan, snap->plan[0] ? snap->plan : "--");
    }

    refresh_status();
}
