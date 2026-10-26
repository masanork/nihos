#include "nihos_allocator.h"
#include <stdint.h>

/* Called by both native busy workers on both harts. All usable bytes, including
 * class padding, must survive a later moving resize after in-place shrink. */
unsigned char *nih_c_allocator_probe(void);
unsigned char *nih_c_allocator_probe(void) {
    unsigned char local = 0;
    if (nih_task_malloc(1) || nih_task_capacity(&local) || nih_task_free(&local) != -1) return NULL;
    if (nih_task_allocator_open(0) != -1 || nih_task_allocator_open(2) != 0) return NULL;
    if (nih_task_allocator_open(2) != -1 || nih_task_free(NULL) != 0) return NULL;
    if (nih_task_malloc(0) || nih_task_malloc(SIZE_MAX) || nih_task_realloc(NULL, 0)) return NULL;
    unsigned char *p = nih_task_malloc(13);
    if (!p || (uintptr_t)p % 8 || nih_task_capacity(p) != 16) return NULL;
    if (nih_task_capacity(p + 1) || nih_task_free(p + 1) != -1 || nih_task_realloc(p + 1, 32)) return NULL;
    for (size_t i = 0; i < 16; ++i) p[i] = (unsigned char)(0x40 + i);
    unsigned char *q = nih_task_realloc(p, 300);
    if (!q || q == p || nih_task_capacity(q) != 512 || nih_task_capacity(p)) return NULL;
    for (size_t i = 0; i < 16; ++i) if (q[i] != (unsigned char)(0x40 + i)) return NULL;
    for (size_t i = 0; i < 512; ++i) q[i] = (unsigned char)(i % 251);
    if (nih_task_realloc(q, 9) != q || nih_task_capacity(q) != 512) return NULL;
    void *block0 = nih_task_malloc(4096), *block1 = nih_task_malloc(4096);
    if (!block0 || !block1 || nih_task_realloc(q, 4096) || nih_task_realloc(q, 4097)) return NULL;
    if (nih_task_capacity(q) != 512) return NULL;
    for (size_t i = 0; i < 512; ++i) if (q[i] != (unsigned char)(i % 251)) return NULL;
    if (nih_task_free(block0) != 0 || nih_task_free(block1) != 0) return NULL;
    p = nih_task_realloc(q, 1024);
    if (!p || p == q || nih_task_capacity(p) != 1024) return NULL;
    for (size_t i = 0; i < 512; ++i) if (p[i] != (unsigned char)(i % 251)) return NULL;
    if (nih_task_realloc(p, 0) || nih_task_capacity(p) || nih_task_free(p) != -1) return NULL;
    if (nih_task_roundup(0) || nih_task_roundup(4097) || nih_task_roundup(13) != 16) return NULL;
    if (nih_task_allocator_close() != 0 || nih_task_allocator_close() != -1 || nih_task_malloc(1)) return NULL;
    if (nih_task_allocator_open(2) != 0) return NULL;
    p = nih_task_realloc(NULL, 8);
    if (!p) return NULL;
    for (size_t i = 0; i < 8; ++i) p[i] = 0x39;
    return p; /* deliberately retained for task exit, no per-cell destructor */
}
