/* Test-only monotonic arena: one instance per operation; never production RNG. */
#include "mlkem_arena.h"
void *nih_mlkem_alloc(void *ctx, size_t bytes) {
    struct nih_mlkem_arena *a = ctx;
    if (!a || !a->bytes || a->used > a->capacity) return NULL;
    a->attempts++;
    if ((a->fail_at && a->attempts == a->fail_at) || bytes > SIZE_MAX - 31) return NULL;
    size_t rounded = (bytes + 31) & ~(size_t)31;
    if (rounded > a->capacity - a->used) return NULL;
    void *ptr = a->bytes + a->used;
    a->used += rounded;
    if (a->used > a->peak) a->peak = a->used;
    a->allocs++;
    a->live++;
    return ptr;
}
void nih_mlkem_free(void *ctx, void *ptr, size_t bytes) {
    struct nih_mlkem_arena *a = ctx;
    if (!a || !ptr || !a->live) return;
    const uint8_t *p = ptr;
    for (size_t i = 0; i < bytes; i++) if (p[i] != 0) { a->uncleared++; break; }
    a->frees++;
    a->live--;
}
