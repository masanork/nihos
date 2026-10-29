#ifndef NIH_PQC_ARENA_H
#define NIH_PQC_ARENA_H
#include <stddef.h>
#include <stdint.h>
struct nih_pqc_arena {
    uint8_t *bytes;
    size_t capacity;
    size_t used;
    size_t peak;
    unsigned allocs;
    unsigned frees;
    unsigned failures;
    unsigned live;
};
void *nih_pqc_arena_alloc(void *ctx, size_t bytes);
void nih_pqc_arena_free(void *ctx, void *ptr, size_t bytes);
#define MLD_CONFIG_CUSTOM_ALLOC_FREE
#define MLD_CONFIG_CONTEXT_PARAMETER
#define MLD_CONFIG_CONTEXT_PARAMETER_TYPE void *
#define MLD_CUSTOM_ALLOC(v, T, N, ctx) T *(v) = (T *)nih_pqc_arena_alloc((ctx), sizeof(T) * (N))
#define MLD_CUSTOM_FREE(v, T, N, ctx) nih_pqc_arena_free((ctx), (v), sizeof(T) * (N))
#endif
