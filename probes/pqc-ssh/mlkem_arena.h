#ifndef NIH_MLKEM_ARENA_H
#define NIH_MLKEM_ARENA_H
#include <stddef.h>
#include <stdint.h>
struct nih_mlkem_arena {
    uint8_t *bytes;
    size_t capacity, used, peak;
    unsigned attempts, fail_at, allocs, frees, live, uncleared;
};
void *nih_mlkem_alloc(void *, size_t);
void nih_mlkem_free(void *, void *, size_t);
#define MLK_CONFIG_CUSTOM_ALLOC_FREE
#define MLK_CONFIG_CONTEXT_PARAMETER
#define MLK_CONFIG_CONTEXT_PARAMETER_TYPE void *
#define MLK_CUSTOM_ALLOC(v, T, N, ctx) T *(v) = (T *)nih_mlkem_alloc((ctx), sizeof(T) * (N))
#define MLK_CUSTOM_FREE(v, T, N, ctx) nih_mlkem_free((ctx), (v), sizeof(T) * (N))
#endif
