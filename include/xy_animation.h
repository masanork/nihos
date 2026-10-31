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
/* Labels: width 32..1280, height 24..180, font size 8..64, RGB colors. */
bool xy_label_render_bgra8(uint8_t *, size_t, const uint8_t *, uint32_t,
                         uint32_t, uint32_t, uint8_t, uint32_t, uint32_t, bool);
#endif
