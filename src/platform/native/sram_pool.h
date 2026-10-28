/* Bounded address-only SRAM allocator. The base supplies all free extents.
 * Serialized by the native adapter; never touches the allocated memory. */
#ifndef NIH_SRAM_POOL_H
#define NIH_SRAM_POOL_H
#include <stdbool.h>
#include <stdint.h>
#ifndef NIH_SRAM_FOREGROUND
#define NIH_SRAM_FOREGROUND
#endif
typedef struct { uint32_t start, bytes; } nih_sram_region;
typedef struct { uint32_t start, bytes, generation, owner; } nih_sram_lease;
typedef struct {
    nih_sram_region regions[2];
    nih_sram_lease leases[16];
    uint32_t generation;
    bool ready;
} nih_sram_pool;
static inline NIH_SRAM_FOREGROUND bool nih_sram_pool_init(nih_sram_pool *p, const nih_sram_region regions[2]) {
    if (p->ready) return false;
    for (uint32_t i = 0; i < 2; ++i) {
        if (!regions[i].bytes || (regions[i].start & 63) || (regions[i].bytes & 63) ||
            regions[i].bytes > UINT32_MAX - regions[i].start) return false;
    }
    if (regions[0].start + regions[0].bytes > regions[1].start) return false;
    p->regions[0] = regions[0]; p->regions[1] = regions[1]; p->ready = true;
    return true;
}
static inline NIH_SRAM_FOREGROUND bool nih_sram_pool_take(nih_sram_pool *p, uint32_t owner, uint32_t minimum,
                                     uint32_t maximum, nih_sram_lease *out) {
    if (!p->ready || !owner || !minimum || minimum > maximum || (minimum & 63) || (maximum & 63) ||
        p->generation == UINT32_MAX) return false;
    uint32_t slot = 16, best = 0, start = 0;
    for (uint32_t i = 0; i < 16; ++i) if (!p->leases[i].owner) { slot = i; break; }
    if (slot == 16) return false;
    for (uint32_t r = 0; r < 2; ++r) {
        uint32_t at = p->regions[r].start, end = at + p->regions[r].bytes;
        while (at < end) {
            uint32_t next = end, skip = at;
            for (uint32_t i = 0; i < 16; ++i) {
                const nih_sram_lease l = p->leases[i];
                if (!l.owner) continue;
                if (l.start <= at && l.start + l.bytes > at) skip = l.start + l.bytes;
                else if (l.start > at && l.start < next) next = l.start;
            }
            if (skip > at) { at = skip; continue; }
            const uint32_t available = next - at;
            const uint32_t bytes = available < maximum ? available : maximum;
            if (bytes > best) { best = bytes; start = at; }
            if (best == maximum || next == end) break;
            at = next;
        }
        if (best == maximum) break;
    }
    if (best < minimum) return false;
    const nih_sram_lease result = {start, best, ++p->generation, owner};
    p->leases[slot] = result; *out = result;
    return true;
}
static inline NIH_SRAM_FOREGROUND bool nih_sram_pool_release(nih_sram_pool *p, const nih_sram_lease *lease) {
    if (!p->ready || !lease->owner) return false;
    for (uint32_t i = 0; i < 16; ++i) {
        nih_sram_lease *l = &p->leases[i];
        if (l->owner == lease->owner && l->generation == lease->generation &&
            l->start == lease->start && l->bytes == lease->bytes) {
            *l = (nih_sram_lease){0}; return true;
        }
    }
    return false;
}
#endif
