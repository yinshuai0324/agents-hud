#include "idle.h"

#include "esp_err.h"
#include "lvgl.h"
#include "bsp/display.h"

/* No touch and no work/notify/error for this long -> screen off. */
#define IDLE_TIMEOUT_MS (15UL * 60UL * 1000UL)
#define BRIGHT_ACTIVE 100
/* Fade speed: percent per 40ms tick (out gentle, in snappy). */
#define FADE_OUT_STEP 3
#define FADE_IN_STEP 10

static volatile uint32_t s_last_activity;
static int s_brightness = BRIGHT_ACTIVE;

void idle_note_activity(void)
{
    s_last_activity = lv_tick_get();
}

bool idle_is_asleep(void)
{
    return s_brightness == 0;
}

bool idle_consume_wake(void)
{
    /* Swallow the touch unless the panel is fully awake. */
    bool consumed = s_brightness < BRIGHT_ACTIVE;
    idle_note_activity();
    return consumed;
}

void idle_force_sleep(void)
{
    s_last_activity = lv_tick_get() - IDLE_TIMEOUT_MS;
}

static void idle_timer_cb(lv_timer_t *t)
{
    (void)t;
    bool want_awake = (lv_tick_get() - s_last_activity) < IDLE_TIMEOUT_MS;
    int target = want_awake ? BRIGHT_ACTIVE : 0;
    if (s_brightness == target) return;

    if (target > s_brightness) {
        s_brightness += FADE_IN_STEP;
        if (s_brightness > target) s_brightness = target;
    } else {
        s_brightness -= FADE_OUT_STEP;
        if (s_brightness < target) s_brightness = target;
    }
    bsp_display_brightness_set(s_brightness);
}

void idle_init(void)
{
    s_last_activity = lv_tick_get();
    lv_timer_create(idle_timer_cb, 40, NULL);
}
