#include "nihos_allocator.h"
#include <stdint.h>
#include <stdio.h>
unsigned char *nih_c_allocator_probe(void);
int nih_host_select(uint16_t slot);
int nih_host_retire(void);
int nih_host_recovered(void);
int main(void) {
    unsigned char *retained = nih_c_allocator_probe();
    if (!retained || nih_host_select(1) || nih_task_allocator_open(2)) return 1;
    if (nih_task_capacity(retained) || nih_task_free(retained) != -1 || nih_task_realloc(retained, 16)) return 2;
    if (nih_host_retire() || nih_host_select(0)) return 3;
    for (size_t i = 0; i < 8; ++i) if (retained[i] != 0x39) return 4;
    if (nih_host_retire() || nih_task_capacity(retained) || nih_task_malloc(8) || !nih_host_recovered()) return 5;
    puts("C allocator host PASS: capacity-copy, OOM, foreign task, retirement/recovery");
    return 0;
}
