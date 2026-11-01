#ifndef NIHOS_APP_H
#define NIHOS_APP_H
#include <stddef.h>
#include <stdint.h>
/* v1 native C boundary. Struct sizes/offsets are fixed, but pointers and
 * size_t are native: this is NOT a Wasm linear-memory ABI. Single synchronous
 * foreground owner. All pointers must be valid, aligned and non-overlapping;
 * outputs are exclusively borrowed until return. No pointer is retained.
 * Exact version and struct size are required, reserved fields must be zero.
 * Validation failures leave state, output bytes and metadata unchanged.
 */
#define NIH_APP_VERSION 1u
enum nih_app_status {
    NIH_APP_OK = 0, NIH_APP_CHANGED = 1, NIH_APP_INVALID = -1,
    NIH_APP_UNSUPPORTED_VERSION = -2, NIH_APP_CLOSED = -3,
    NIH_APP_RENDER_FAILED = -4, NIH_APP_INACTIVE = -5
};
enum nih_app_event_kind {
    NIH_APP_TICK, NIH_APP_KEY_DOWN, NIH_APP_KEY_UP,
    NIH_APP_FOCUS_LOST, NIH_APP_FOCUS_GAINED, NIH_APP_CANCEL
};
enum nih_app_format { NIH_APP_RGB565LE = 1, NIH_APP_BGRA8 = 2 };
enum nih_app_pane { NIH_APP_GRAPH, NIH_APP_EDITOR };
typedef struct {
    uint32_t size, abi_version;
    uint64_t monotonic_us;
    uint32_t kind, code, value, reserved;
} nih_app_event;
typedef struct {
    uint32_t size, abi_version, min_width, min_height, max_width, max_height;
    uint32_t stride_limit, frame_bytes_limit, format_mask, key_count;
    uint32_t step_us, catch_up_steps;
} nih_app_info;
typedef struct {
    uint32_t size, abi_version;
    uint64_t ticks, phase, generation, dropped_us;
    uint32_t paused, speed, held, pressed, released, stopped, focused, reserved;
} nih_app_snapshot;
typedef struct {
    uint32_t size, abi_version, width, height, stride, format, pane, reserved;
} nih_app_frame_request;
typedef struct {
    uint32_t size, abi_version;
    uint64_t generation;
    uint32_t width, height, stride, format, byte_length, reserved;
} nih_app_frame_info;
#ifdef __cplusplus
extern "C" {
#endif
/* Prototype's graph/editor implementation of the common contract. Open resets
 * the RAM editor as well as graph state. Cancel is idempotent and terminal;
 * only another successful open starts a new session. Query works when closed.
 */
int32_t xy_app_query(uint32_t version, nih_app_info *out, uint32_t out_size);
int32_t xy_app_open(uint32_t version);
/* Key slots 0..31; plot maps 0 pause, 1 slower, 2 faster, 3 reset.
 * held is current state. pressed/released describe ONLY the last accepted
 * event, including input released on focus loss/cancel. Repeated down has no
 * new pressed edge. Focus loss pauses, releases all keys and drops fractional
 * time. Focus gain rebases time and does not resume. Keys while unfocused fail.
 * Tick catch-up <=4 steps of 16,667us; dropped time is observable. Cancel/focus
 * loss never executes an extra update, even after a long clock gap.
 */
int32_t xy_app_event(const nih_app_event *event);
int32_t xy_app_state(uint32_t version, nih_app_snapshot *out, uint32_t out_size);
/* Caller owns and may reuse/free frame bytes immediately after return (copy
 * them first if a presentation backend retains storage). Successful render
 * writes active pixels, preserves ALL row padding and excess capacity, and
 * publishes metadata last. Requires capacity >= stride*height, including last
 * row padding. Rendering does not tick or consume input edges. generation is
 * pane-local and comparable only within a session; open invalidates it.
 * Render-failed leaves caller outputs untouched too. No completion callback,
 * frame handle or implicit presentation. GPU atlas retirement belongs to host.
 */
int32_t xy_app_frame(const nih_app_frame_request *, uint8_t *out, size_t capacity,
                     nih_app_frame_info *metadata, uint32_t metadata_size);
#ifdef __cplusplus
}
#endif
#endif
