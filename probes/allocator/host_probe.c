#include "nihos_allocator.h"
#include <stdint.h>
#include <stdio.h>
#include <pthread.h>
unsigned char *nih_c_allocator_probe(void);
int nih_host_select(uint16_t slot);
int nih_host_retire(void);
int nih_host_recovered(void);
struct identity_check { uint32_t original, observed; int status; };
static void *check_identity(void *argument) {
    struct identity_check *check = argument;
    check->status = nih_host_select(1);
    check->observed = nih_task_identity();
    return NULL;
}
int main(void) {
    const uint32_t original = nih_task_identity();
    if (!original || original != nih_task_identity()) return 6;
    struct identity_check check = { .original = original, .observed = 0, .status = -1 };
    pthread_t peer;
    if (pthread_create(&peer, NULL, check_identity, &check) || pthread_join(peer, NULL)) return 9;
    if (check.status || !check.observed || check.observed == original || nih_task_identity() != original) return 10;
    unsigned char *retained = nih_c_allocator_probe();
    if (!retained || nih_host_select(1) || nih_task_allocator_open(2)) return 1;
    if (nih_task_identity() == original || !nih_task_identity()) return 7;
    if (nih_task_capacity(retained) || nih_task_free(retained) != -1 || nih_task_realloc(retained, 16)) return 2;
    if (nih_host_retire() || nih_host_select(0)) return 3;
    for (size_t i = 0; i < 8; ++i) if (retained[i] != 0x39) return 4;
    if (nih_host_retire() || nih_task_capacity(retained) || nih_task_malloc(8) || !nih_host_recovered()) return 5;
    if (!nih_task_identity() || nih_task_identity() == original) return 8;
    puts("C allocator host PASS: capacity-copy, OOM, foreign task, retirement/recovery");
    return 0;
}
