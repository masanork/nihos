/* Native record layout checked by both C and the Zig/Rust integration. */
#include "nihos_app.h"
#include "xy_animation.h"
_Static_assert(sizeof(nih_app_event) == 32, "event layout");
_Static_assert(offsetof(nih_app_event, monotonic_us) == 8, "timestamp offset");
_Static_assert(sizeof(nih_app_info) == 48, "info layout");
_Static_assert(sizeof(nih_app_snapshot) == 72, "state layout");
_Static_assert(offsetof(nih_app_snapshot, held) == 48, "input offset");
_Static_assert(sizeof(nih_app_frame_request) == 32, "request layout");
_Static_assert(sizeof(nih_app_frame_info) == 40, "frame layout");
_Static_assert(offsetof(nih_app_frame_info, generation) == 8, "generation offset");
