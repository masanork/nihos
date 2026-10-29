#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
struct nih_pqc_result { uint32_t valid, rejected, oom, peak, allocs, frees, failures, live, verify_ticks, verify_worker0, verify_worker1; };
int nih_pqc_arena_fixture(uint8_t *, size_t, struct nih_pqc_result *);
void nih_pqc_observe(uint32_t out[3]) { out[0] = out[1] = out[2] = 0; }
int main(void) {
    static _Alignas(64) uint8_t area[16304];
    struct nih_pqc_result r = {0};
    int result = nih_pqc_arena_fixture(area, sizeof(area), &r);
    printf("result=%d valid=%u rejected=%u oom=%u peak=%u allocs=%u frees=%u failures=%u live=%u\n", result, r.valid, r.rejected, r.oom, r.peak, r.allocs, r.frees, r.failures, r.live);
    return result;
}
