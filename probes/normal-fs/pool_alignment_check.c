/* Synthetic address-only pool. Does not access a device or dereference leases. */
#include "sram_pool.h"
#include <stdio.h>
int main(void) {
    nih_sram_pool pool = {0};
    const nih_sram_region regions[2] = {{0x1000, 65600}, {0x20000, 64}};
    nih_sram_lease prefix = {0}, fs = {0};
    if (!nih_sram_pool_init(&pool, regions) ||
        !nih_sram_pool_take(&pool, 1, 64, 64, &prefix) ||
        !nih_sram_pool_take(&pool, 2, 65536, 65536, &fs)) return 1;
    if ((fs.start & 63) != 0 || (fs.start & 127) != 64) return 2;
    printf("{\"prefix_start\":%u,\"fs_start\":%u,\"fs_bytes\":%u,\"fs_mod_128\":%u}\n",
           prefix.start, fs.start, fs.bytes, fs.start & 127);
    return 0;
}
