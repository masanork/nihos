#ifndef NIH_SQLITE_STORE_ALLOCATOR_H
#define NIH_SQLITE_STORE_ALLOCATOR_H
const char *nih_store_allocator_class_peaks(void);
const char *nih_store_allocator_quotas(void);
int nih_store_memory_setup(const char *profile);
int nih_store_memory_shutdown_ok(void);
int nih_store_rows(void);
int nih_store_cache_pages(void);
int nih_store_cache_kib(void);
int nih_store_allocator_is_bounded(void);
unsigned long long nih_store_allocator_attempts(void);
unsigned long long nih_store_allocator_injected(void);
unsigned long long nih_store_allocator_rejected(void);
unsigned long long nih_store_allocator_max_request(void);
unsigned long long nih_store_allocator_parent_bytes(void);
unsigned long long nih_store_allocator_reserved_bytes(void);
unsigned long long nih_store_pagecache_bytes(void);
unsigned long long nih_store_pagecache_cell_bytes(void);
unsigned long long nih_store_pagecache_cells(void);
#endif
