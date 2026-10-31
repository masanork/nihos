#ifndef NIHOS_XY_ANIMATION_H
#define NIHOS_XY_ANIMATION_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "nihos_app.h"
/* Editor/label helpers for the GPUI prototype; event/state/frame operations use
 * nihos_app.h. Same single-owner, synchronous borrowed-buffer rules apply. */
bool xy_editor_insert(const uint8_t *, uint32_t);
/* editor key: 0 left, 1 right, 2 backspace, 3 undo, 4 newline. */
bool xy_editor_key(uint8_t);
/* Bounded Scheme prototype helpers sharing the editor VM. Reply capacity 1..256,
 * source <=4096 UTF-8 bytes; >=0 is reply length, negative is failure. On a
 * Scheme error VM/document/plot changes roll back, callback is cleared and
 * animation pauses; error text is available separately. No wall-clock deadline
 * or resumable evaluation: one callback <=256 evaluator steps, depth <=24,
 * 64 heap cells reserved for subsequent recovery. App v1 records are unchanged.
 */
int32_t xy_app_scheme_eval(const uint8_t *, uint32_t, uint8_t *, uint32_t, uint64_t);
int32_t xy_app_scheme_eval_buffer(uint8_t *, uint32_t, uint64_t);
uint32_t xy_app_scheme_error(uint8_t *, uint32_t);
bool xy_app_scheme_registered(void);
uint64_t xy_app_editor_generation(void);
/* Labels: width 32..1280, height 24..180, font size 8..64, RGB colors. */
bool xy_label_render_bgra8(uint8_t *, size_t, const uint8_t *, uint32_t,
                         uint32_t, uint32_t, uint8_t, uint32_t, uint32_t, bool);
#endif
