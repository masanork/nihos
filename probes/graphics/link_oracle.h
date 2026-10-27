#ifndef NIHOS_GRAPHICS_LINK_ORACLE_H
#define NIHOS_GRAPHICS_LINK_ORACLE_H
#include <stdint.h>
struct GraphicsInputs {
    const unsigned char *fonts[2];
    uint32_t lengths[2];
    unsigned char *heap;
    uint32_t heap_bytes;
};
struct GraphicsResult {
    uint32_t magic, stage, failure, runs, hashes[16];
    uint32_t pool_peak, raw_peak, retained, largest_extent, unavailable_calls, runtime_malloc_calls;
};
extern "C" {
extern GraphicsResult graphics_result;
int graphics_font_link_probe(const GraphicsInputs *inputs);
}
#endif
