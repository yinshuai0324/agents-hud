#pragma once

#include <stdbool.h>

/**
 * AMOLED burn-in protection: fade the panel to black after a stretch with
 * no touch and no attention-worthy session state; fade back in on touch
 * or when work/notify/error activity resumes.
 */

/** Create the fade timer. Call once with the LVGL/display lock held. */
void idle_init(void);

/** Note wake-worthy activity (touch, button, working/notify/error state). */
void idle_note_activity(void);

/** True while the panel is (mostly) dark. */
bool idle_is_asleep(void);

/**
 * Call on a touch event. Returns true if the touch was consumed as a
 * wake-up and the caller must skip its normal action.
 */
bool idle_consume_wake(void);

/** Force the idle timeout to elapse now (console 'z', for testing). */
void idle_force_sleep(void);
