/* CPU0-serialized two-slot producer/consumer policy. Payloads stay pinned. */
#ifndef NIH_CAMERA_DMA_POOL_H
#define NIH_CAMERA_DMA_POOL_H
#include <stdbool.h>
#include <stdint.h>
typedef struct {
    uint32_t generation, ready_generation, borrowed_generation, dropped;
    int dma, ready, borrowed;
} camera_dma_pool;
static inline void camera_pool_init(camera_dma_pool *p) {
    *p = (camera_dma_pool){ .dma = 0, .ready = -1, .borrowed = -1 };
}
/* Called at completed transfer, before rearming the returned target. */
static inline int camera_pool_complete(camera_dma_pool *p) {
    if (p->generation == UINT32_MAX) return -1;
    ++p->generation;
    if (p->borrowed >= 0) {
        ++p->dropped;
        return p->dma; /* never overwrite the consumer's other slot */
    }
    if (p->ready >= 0) ++p->dropped;
    p->ready = p->dma;
    p->ready_generation = p->generation;
    p->dma ^= 1;
    return p->dma;
}
static inline int camera_pool_borrow(camera_dma_pool *p, uint32_t *generation) {
    if (!generation || p->borrowed >= 0 || p->ready < 0) return -1;
    p->borrowed = p->ready;
    p->borrowed_generation = p->ready_generation;
    p->ready = -1;
    *generation = p->borrowed_generation;
    return p->borrowed;
}
static inline bool camera_pool_release(camera_dma_pool *p, uint32_t generation) {
    if (p->borrowed < 0 || p->borrowed_generation != generation) return false;
    p->borrowed = -1;
    return true;
}
#endif
