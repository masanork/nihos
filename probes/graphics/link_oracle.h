#ifndef NIHOS_GRAPHICS_LINK_ORACLE_H
#define NIHOS_GRAPHICS_LINK_ORACLE_H
#include <stdint.h>
struct GraphicsInputs {
    const unsigned char *fonts[2];
    uint32_t lengths[2];
    unsigned char *heap;
    uint32_t heap_bytes;
    // 0: default, 1: force auto-hint, 2: no hinting (including auto-hint).
    uint32_t load_mode;
};
struct GraphicsRender {
    uint32_t font, pixels, vertical, hinting, body_length, ruby_length;
    char body[128], ruby[64];
};
struct GraphicsJob { uint32_t operation; GraphicsRender render; };
static_assert(sizeof(GraphicsRender)==216 && sizeof(GraphicsJob)==220, "text request ABI");
struct GraphicsResult {
    uint32_t magic, stage, failure, runs, hashes[16];
    uint32_t pool_peak, raw_peak, retained, largest_extent, unavailable_calls, runtime_malloc_calls;
    uint32_t controller_bytes, record_capacity, record_peak, record_failures, allocation_failures;
};
extern "C" {
extern GraphicsResult graphics_result;
int graphics_font_link_probe(const GraphicsInputs *inputs);
}
#endif
