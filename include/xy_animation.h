#ifndef NIHOS_XY_ANIMATION_H
#define NIHOS_XY_ANIMATION_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
/* Single foreground owner; synchronous borrowed buffers. No pointer survives
 * a call. Frame geometry is 240..1280 by 180..720, tightly packed RGB565LE/BGRA8.
 * Experimental host API, not the Wasm ABI or an R7RS library. */
typedef struct {
    uint64_t ticks, phase, generation, dropped_us;
    uint32_t paused, speed, held;
} xy_animation_snapshot;
bool xy_animation_init(void);
bool xy_animation_tick(uint64_t monotonic_us);
/* key: 0 pause, 1 slower, 2 faster, 3 reset; repeated down is suppressed. */
bool xy_animation_key(uint8_t key, bool down, uint64_t monotonic_us);
void xy_animation_focus_lost(uint64_t monotonic_us);
void xy_animation_state(xy_animation_snapshot *out);
bool xy_animation_render_rgb565(uint8_t *, size_t, uint32_t, uint32_t);
bool xy_animation_render_bgra8(uint8_t *, size_t, uint32_t, uint32_t);
bool xy_editor_render_bgra8(uint8_t *, size_t, uint32_t, uint32_t);
bool xy_editor_insert(const uint8_t *, uint32_t);
/* editor key: 0 left, 1 right, 2 backspace, 3 undo, 4 newline. */
bool xy_editor_key(uint8_t);
/* Labels: width 32..1280, height 24..180, font size 8..64, RGB colors. */
bool xy_label_render_bgra8(uint8_t *, size_t, const uint8_t *, uint32_t,
                         uint32_t, uint32_t, uint8_t, uint32_t, uint32_t, bool);
#endif
