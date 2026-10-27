/* Host experiment: SQLite page cache is separate from the existing <=4KiB
 * task-owned pool. No production allocator ABI or profile is changed. */
#include "store_allocator.h"
#include "nihos_allocator.h"
#include "sqlite3.h"
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

size_t nih_host_parent_bytes(void);
size_t nih_host_reserved_bytes(void);
int nih_host_recovered(void);
void *nih_host_large_alloc(size_t bytes);
size_t nih_host_large_capacity(void *pointer);
int nih_host_large_free(void *pointer);
int nih_host_allocator_open_config(const uint16_t *counts, size_t count);
static const uint16_t quotas[10] = {40,16,64,64,64,6,10,16,8,1};
static sqlite3_mem_methods original;
static int bounded, cache_kib = 32, rows = 64, live, shutdown_failed, opened;
static long long fail_after = -1;
static unsigned long long attempts, injected, rejected, max_request, parent_bytes, reserved_bytes;
static int cell_bytes, cells;
static unsigned live_classes[16], peak_classes[16];
static char peaks[256], quota_text[128];
static int size_of(void *p);
static unsigned index_of(int size) {
    unsigned i = 0; unsigned long long n = 8;
    while (n < (unsigned)size && i < 15) { n *= 2; ++i; }
    return i;
}
static void add_class(void *p) {
    unsigned i = index_of(size_of(p));
    if (++live_classes[i] > peak_classes[i]) peak_classes[i] = live_classes[i];
}
static void remove_class(void *p) { unsigned i = index_of(size_of(p)); if (!live_classes[i]--) abort(); }
const char *nih_store_allocator_class_peaks(void) {
    size_t position = 0;
    peaks[position++] = '[';
    for (unsigned i = 0; i < 16; ++i) {
        int n = snprintf(peaks + position, sizeof(peaks) - position, "%s%u", i ? "," : "", peak_classes[i]);
        if (n < 0 || (size_t)n >= sizeof(peaks) - position) abort();
        position += (size_t)n;
    }
    peaks[position++] = ']'; peaks[position] = 0;
    return peaks;
}
static _Alignas(8) unsigned char pagecache[512 * 1024];
static int inject(void) {
    unsigned long long index = attempts++;
    if (fail_after >= 0 && index == (unsigned long long)fail_after) { ++injected; return 1; }
    return 0;
}
static void *allocate(int bytes) {
    if (bytes <= 0 || inject()) return NULL;
    void *p = bounded ? (bytes <= 4096 ? nih_task_malloc((size_t)bytes) : nih_host_large_alloc((size_t)bytes)) : original.xMalloc(bytes);
    if (p) { ++live; add_class(p); if (bounded && nih_host_reserved_bytes() > reserved_bytes) reserved_bytes = nih_host_reserved_bytes(); }
    else { ++rejected; fprintf(stderr, "ALLOCATOR_REJECT bytes=%d peaks=%s\n", bytes, nih_store_allocator_class_peaks()); fflush(stderr); }
    return p;
}
static void release(void *p) {
    if (!p) return;
    if (--live < 0) abort();
    remove_class(p);
    if (bounded) { if (nih_host_large_capacity(p) ? nih_host_large_free(p) : nih_task_free(p)) abort(); } else original.xFree(p);
}
static void *resize(void *p, int bytes) {
    if (!p) return allocate(bytes);
    if (bytes <= 0) { release(p); return NULL; }
    if (inject()) return NULL;
    unsigned old_class = index_of(size_of(p));
    void *next;
    if (!bounded) next = original.xRealloc(p, bytes);
    else if (nih_host_large_capacity(p)) next = (size_t)bytes <= nih_host_large_capacity(p) ? p : NULL;
    else if (bytes <= 4096) next = nih_task_realloc(p, (size_t)bytes);
    else {
        next = nih_host_large_alloc((size_t)bytes);
        if (next) { memcpy(next, p, nih_task_capacity(p)); if (nih_task_free(p)) abort(); }
    }
    if (!next) ++rejected;
    else {
        if (!live_classes[old_class]--) abort();
        add_class(next);
        if (bounded && nih_host_reserved_bytes() > reserved_bytes) reserved_bytes = nih_host_reserved_bytes();
    }
    return next;
}
static int size_of(void *p) {
    if (!bounded) return original.xSize(p);
    size_t n = nih_host_large_capacity(p);
    return (int)(n ? n : nih_task_capacity(p));
}
static int round_up(int bytes) {
    if (bytes <= 0) return 0;
    if ((unsigned long long)bytes > max_request) max_request = (unsigned long long)bytes;
    if (!bounded) return original.xRoundup(bytes);
    size_t n = bytes > 4096 ? (bytes <= 8192 ? (size_t)8192 : 0) : nih_task_roundup((size_t)bytes);
    if (!n) ++rejected;
    return (int)n;
}
static int initialize(void *context) {
    (void)context;
    if (!bounded) return original.xInit ? original.xInit(original.pAppData) : SQLITE_OK;
    if (nih_host_allocator_open_config(quotas, 10)) return SQLITE_NOMEM;
    opened = 1;
    parent_bytes = nih_host_parent_bytes(); reserved_bytes = nih_host_reserved_bytes();
    return SQLITE_OK;
}
static void shutdown_memory(void *context) {
    (void)context;
    if (live) shutdown_failed = 1;
    if (bounded) {
        if (opened && nih_task_allocator_close()) shutdown_failed = 1;
        opened = 0;
        if (!nih_host_recovered()) shutdown_failed = 1;
    } else if (original.xShutdown) original.xShutdown(original.pAppData);
}
static const sqlite3_mem_methods methods = { allocate, release, resize, size_of, round_up, initialize, shutdown_memory, NULL };
int nih_store_memory_setup(const char *profile) {
    const char *at = strchr(profile, ':');
    size_t name_bytes = at ? (size_t)(at - profile) : strlen(profile);
    if (name_bytes > 6 && !memcmp(profile + name_bytes - 6, "-large", 6)) { rows = 640; name_bytes -= 6; }
    if (name_bytes == 6 && !memcmp(profile, "host32", 6)) cache_kib = 32;
    else if (name_bytes == 7 && !memcmp(profile, "host512", 7)) cache_kib = 512;
    else if (name_bytes == 7 && !memcmp(profile, "pool512", 7)) { cache_kib = 512; bounded = 1; }
    else return SQLITE_MISUSE;
    if (at) {
        char *end = NULL; fail_after = strtoll(at + 1, &end, 10);
        if (!* (at + 1) || !end || *end || fail_after < 0) return SQLITE_MISUSE;
    }
    if (sqlite3_config(SQLITE_CONFIG_GETMALLOC, &original) != SQLITE_OK ||
        sqlite3_config(SQLITE_CONFIG_MALLOC, &methods) != SQLITE_OK ||
        sqlite3_config(SQLITE_CONFIG_LOOKASIDE, 0, 0) != SQLITE_OK) return SQLITE_ERROR;
    if (bounded) {
        int header = 0;
        if (sqlite3_config(SQLITE_CONFIG_PCACHE_HDRSZ, &header) != SQLITE_OK || header < 0 || header > 4096) return SQLITE_ERROR;
        cell_bytes = (4096 + header + 7) & ~7;
        cells = (int)(sizeof(pagecache) / (size_t)cell_bytes);
        if (sqlite3_config(SQLITE_CONFIG_PAGECACHE, pagecache, cell_bytes, cells) != SQLITE_OK) return SQLITE_ERROR;
    }
    return SQLITE_OK;
}
int nih_store_memory_shutdown_ok(void) { return !live && !shutdown_failed && (!bounded || (!opened && nih_host_recovered())); }
int nih_store_cache_kib(void) { return cache_kib; }
int nih_store_allocator_is_bounded(void) { return bounded; }
unsigned long long nih_store_allocator_attempts(void) { return attempts; }
unsigned long long nih_store_allocator_injected(void) { return injected; }
unsigned long long nih_store_allocator_rejected(void) { return rejected; }
unsigned long long nih_store_allocator_max_request(void) { return max_request; }
unsigned long long nih_store_allocator_parent_bytes(void) { return parent_bytes; }
unsigned long long nih_store_allocator_reserved_bytes(void) { return reserved_bytes; }
unsigned long long nih_store_pagecache_bytes(void) { return bounded ? sizeof(pagecache) : 0; }
unsigned long long nih_store_pagecache_cell_bytes(void) { return (unsigned long long)cell_bytes; }
unsigned long long nih_store_pagecache_cells(void) { return (unsigned long long)cells; }

int nih_store_rows(void) { return rows; }
int nih_store_cache_pages(void) { return bounded ? cells : cache_kib / 4; }

const char *nih_store_allocator_quotas(void) {
    if (!bounded) return "[]";
    size_t position = 0;
    quota_text[position++] = '[';
    for (unsigned i = 0; i < 10; ++i) {
        int n = snprintf(quota_text + position, sizeof(quota_text) - position, "%s%u", i ? "," : "", (unsigned)quotas[i]);
        if (n < 0 || (size_t)n >= sizeof(quota_text) - position) abort();
        position += (size_t)n;
    }
    quota_text[position++] = ']'; quota_text[position] = 0;
    return quota_text;
}
