#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../../src/platform/native/sram_pool.h"
static const nih_sram_region fonts_base[2] = {{0x4ff40000, 128 * 1024}, {0x4ff80000, 124 * 1024}};
static void invariant(const nih_sram_pool *p) {
    for (unsigned i = 0; i < 16; ++i) {
        const nih_sram_lease a = p->leases[i];
        if (!a.owner) continue;
        assert(a.generation && !(a.start & 63) && !(a.bytes & 63));
        bool contained = false;
        for (unsigned r = 0; r < 2; ++r)
            contained |= a.start >= p->regions[r].start && a.start + a.bytes <= p->regions[r].start + p->regions[r].bytes;
        assert(contained);
        for (unsigned j = i + 1; j < 16; ++j) {
            const nih_sram_lease b = p->leases[j];
            assert(!b.owner || a.start + a.bytes <= b.start || b.start + b.bytes <= a.start);
        }
    }
}
int main(void) {
    nih_sram_pool pool = {0}; nih_sram_lease other, low, high, again, out = {1,2,3,4};
    assert(!nih_sram_pool_take(&pool, 1, 64, 64, &out));
    assert(nih_sram_pool_init(&pool, fonts_base));
    assert(!nih_sram_pool_init(&pool, fonts_base));
    assert(nih_sram_pool_take(&pool, 2, 4096, 4096, &other));
    assert(nih_sram_pool_take(&pool, 1, 65536, 131072, &low));
    assert(nih_sram_pool_take(&pool, 1, 8192, 192512, &high));
    invariant(&pool);
    const nih_sram_pool before = pool;
    assert(!nih_sram_pool_take(&pool, 3, 64, 64, &out));
    assert(!memcmp(&pool, &before, sizeof(pool)) && out.start == 1);
    nih_sram_lease bad = low; bad.owner = 9; assert(!nih_sram_pool_release(&pool, &bad));
    bad = low; ++bad.generation; assert(!nih_sram_pool_release(&pool, &bad));
    bad = low; bad.bytes -= 64; assert(!nih_sram_pool_release(&pool, &bad));
    assert(nih_sram_pool_release(&pool, &low));
    assert(nih_sram_pool_take(&pool, 1, low.bytes, low.bytes, &again));
    assert(again.start == low.start && again.generation != low.generation);
    assert(!nih_sram_pool_release(&pool, &low));
    assert(nih_sram_pool_release(&pool, &again));
    assert(nih_sram_pool_release(&pool, &high));
    assert(nih_sram_pool_release(&pool, &other));
    /* A 64-byte prefix creates a legal hole whose first byte is not 128-aligned. */
    nih_sram_pool fragmented = {0};
    const nih_sram_region fragment_regions[2] = {{0x1000, 65664}, {0x20000, 64}};
    nih_sram_lease prefix = {0}, aligned = {0}, tail = {0};
    assert(nih_sram_pool_init(&fragmented, fragment_regions));
    assert(nih_sram_pool_take(&fragmented, 3, 64, 64, &prefix));
    assert(nih_sram_pool_take_aligned(&fragmented, 4, 65536, 65536, 128, &aligned));
    assert(aligned.start == 0x1080 && !(aligned.start & 127));
    assert(nih_sram_pool_take(&fragmented, 5, 64, 64, &tail));
    assert(tail.start == 0x1040); /* alignment padding is not consumed */
    invariant(&fragmented);
    assert(nih_sram_pool_release(&fragmented, &aligned));
    assert(nih_sram_pool_release(&fragmented, &tail));
    assert(nih_sram_pool_release(&fragmented, &prefix));
    const nih_sram_pool snapshot = fragmented;
    nih_sram_lease sentinel = {11, 22, 33, 44};
    assert(!nih_sram_pool_take_aligned(&fragmented, 3, 64, 64, 96, &sentinel));
    assert(!nih_sram_pool_take_aligned(&fragmented, 3, 64, 64, 32, &sentinel));
    assert(!nih_sram_pool_take_aligned(&fragmented, 3, 64, 64, 0x80000000u, &sentinel));
    assert(!memcmp(&fragmented, &snapshot, sizeof(snapshot)) && sentinel.start == 11);
    /* A too-small aligned first gap must not hide a later fitting region. */
    nih_sram_pool second_region = {0};
    const nih_sram_region two_regions[2] = {{0x1000,65536}, {0x20000,65536}};
    assert(nih_sram_pool_init(&second_region, two_regions));
    assert(nih_sram_pool_take(&second_region, 1, 64, 64, &prefix));
    assert(nih_sram_pool_take_aligned(&second_region, 2, 65536, 65536, 128, &out));
    assert(out.start == 0x20000 && out.bytes == 65536);
    invariant(&second_region);
    nih_sram_pool near_end = {0};
    const nih_sram_region end_regions[2] = {{0x1000,64}, {0xfffffe40u,384}};
    assert(nih_sram_pool_init(&near_end, end_regions));
    assert(nih_sram_pool_take_aligned(&near_end, 7, 128, 128, 256, &out));
    assert(out.start == 0xffffff00u);
    invariant(&near_end);
    uint32_t random = 12345;
    for (unsigned round = 0; round < 10000; ++round) {
        random = random * 1664525u + 1013904223u;
        const unsigned index = (random >> 16) % 16;
        if (pool.leases[index].owner) {
            const nih_sram_lease lease = pool.leases[index];
            assert(nih_sram_pool_release(&pool, &lease));
        } else {
            const uint32_t requested = 64 * (1 + (random >> 8) % 1024);
            const uint32_t alignment = 64u << ((random >> 26) % 5);
            if (nih_sram_pool_take_aligned(&pool, index + 1, requested, requested, alignment, &out))
                assert(!(out.start & (alignment - 1)));
        }
        invariant(&pool);
    }
    nih_sram_pool invalid = {0};
    nih_sram_region overlap[2] = {{0x10000, 4096}, {0x10040, 4096}};
    assert(!nih_sram_pool_init(&invalid, overlap) && !invalid.ready);
    puts("Base SRAM replay passed: reserved-font holes, competing owners, OOM, reuse, stale leases, fragmentation");
}
