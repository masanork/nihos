/* Exact task ownership and one 8KiB scratch slot; no native ABI extension. */
#include "nihos_allocator.h"
#include <stdint.h>
#include <string.h>
void *nih_host_large_alloc(size_t);
size_t nih_host_large_capacity(void *);
int nih_host_large_free(void *);
int nih_host_select(uint16_t);
int nih_host_retire(void);
int nih_host_recovered(void);
int main(void) {
    if (nih_host_large_alloc(8192) || nih_task_allocator_open_profile(1)) return 1;
    if (nih_host_large_alloc(8193)) return 2;
    unsigned char *p = nih_host_large_alloc(8192);
    if (!p || (uintptr_t)p % 8 || nih_host_large_capacity(p) != 8192 || nih_host_large_alloc(8192)) return 3;
    memset(p, 0xa5, 8192);
    if (nih_host_large_capacity(p + 1) || nih_host_large_free(p + 1) != -1 || nih_task_allocator_close() != -1) return 4;
    if (nih_host_select(1) || nih_host_large_capacity(p) || nih_host_large_free(p) != -1 || nih_host_select(0)) return 5;
    if (p[0] != 0xa5 || p[8191] != 0xa5 || nih_host_large_free(p) || nih_host_large_capacity(p)) return 6;
    if (nih_task_allocator_close() || !nih_host_recovered()) return 7;
    if (nih_task_allocator_open_profile(1) || !(p = nih_host_large_alloc(8192))) return 8;
    if (nih_host_retire() || !nih_host_recovered() || nih_host_large_capacity(p)) return 9;
    return 0;
}
