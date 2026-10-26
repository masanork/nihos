#ifndef NIHOS_ALLOCATOR_H
#define NIHOS_ALLOCATOR_H
#include <stddef.h>
#include <stdint.h>

/* Explicit task-local pool; count is the quota for EACH 8..4096 size class.
 * Task context, interrupts enabled, no sharing or migration. open/close/free:
 * 0 success, -1 rejection. Allocation/resize: NULL on failure; positive-size
 * failure preserves the old allocation. realloc(p,0) frees p. free(NULL)=0.
 * capacity is usable bytes (0 for invalid/NULL), roundup is a pure request
 * check (0 for zero/>4096). All returned pointers are 8-byte aligned.
 * Raw C pointers cannot distinguish stale addresses after cell/parent reuse.
 * close invalidates every pointer; automatic task cleanup has no destructors.
 */
/* Active task identity including hart, slot and generation; zero if unavailable.
 * Runtime-scoped ownership stamp, valid even before opening a C pool. */
uint32_t nih_task_identity(void);
int nih_task_allocator_open(size_t count);
/* Profile 1: trace-informed SQLite qualification fixture; other IDs are rejected. */
int nih_task_allocator_open_profile(uint32_t profile);
int nih_task_allocator_close(void);
void *nih_task_malloc(size_t bytes);
void *nih_task_realloc(void *pointer, size_t bytes);
int nih_task_free(void *pointer);
size_t nih_task_capacity(void *pointer);
size_t nih_task_roundup(size_t bytes);
#endif
