/* Host-only SQLite allocator qualification. No OS filesystem is available. */
#include "nihos_allocator.h"
#include "sqlite3.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int nih_host_retire(void);
int nih_host_recovered(void);
static int fail_after = -1, attempts, failures, injected, largest, close_failed;
static int histogram[10], live_blocks, class_live[10], class_peak[10];
static size_t quota = 64;
static size_t class_index(size_t bytes) {
    size_t index = 0, capacity = 8;
    while (capacity < bytes) { ++index; capacity *= 2; }
    if (index >= 10) abort();
    return index;
}
static void account_add(size_t bytes) {
    const size_t index = class_index(bytes);
    ++class_live[index];
    if (class_live[index] > class_peak[index]) class_peak[index] = class_live[index];
}
static void account_remove(size_t bytes) {
    if (--class_live[class_index(bytes)] < 0) abort();
}
static int deny_open(sqlite3_vfs *v, const char *name, sqlite3_file *file, int flags, int *out) {
    (void)v; (void)name; (void)file; (void)flags; (void)out;
    return SQLITE_CANTOPEN;
}
static int deny_path(sqlite3_vfs *v, const char *name, int n, char *out) {
    (void)v; (void)name; (void)n; (void)out; return SQLITE_CANTOPEN;
}
static int no_random(sqlite3_vfs *v, int n, char *out) {
    (void)v; memset(out, 0x5a, (size_t)n); return n;
}
static int no_sleep(sqlite3_vfs *v, int n) { (void)v; return n; }
static int fixed_time(sqlite3_vfs *v, double *time) { (void)v; *time = 2440587.5; return SQLITE_OK; }
static sqlite3_vfs noio = {
    .iVersion = 1, .szOsFile = sizeof(sqlite3_file), .mxPathname = 64,
    .zName = "nihos-host-noio", .xOpen = deny_open, .xFullPathname = deny_path,
    .xRandomness = no_random, .xSleep = no_sleep, .xCurrentTime = fixed_time
};
int sqlite3_os_init(void) { return sqlite3_vfs_register(&noio, 1); }
int sqlite3_os_end(void) { return SQLITE_OK; }
static int inject(void) {
    const int fail = fail_after >= 0 && attempts == fail_after;
    ++attempts;
    if (fail) { ++failures; ++injected; }
    return fail;
}
static void *alloc_mem(int n) {
    if (n <= 0 || inject()) return NULL;
    void *p = nih_task_malloc((size_t)n);
    if (p) { ++live_blocks; account_add(nih_task_capacity(p)); }
    else ++failures;
    return p;
}
static void free_mem(void *p) {
    if (p) { --live_blocks; account_remove(nih_task_capacity(p)); }
    if (nih_task_free(p)) abort();
}
static void *resize_mem(void *p, int n) {
    if (n <= 0 || inject()) return NULL;
    const size_t old_size = nih_task_capacity(p);
    void *next = nih_task_realloc(p, (size_t)n);
    if (next) {
        const size_t next_size = nih_task_capacity(next);
        if (!p) { ++live_blocks; account_add(next_size); }
        else if (old_size != next_size) { account_add(next_size); account_remove(old_size); }
    } else ++failures;
    return next;
}
static int size_mem(void *p) { return (int)nih_task_capacity(p); }
static int round_mem(int n) {
    if (n <= 0) return 0;
    if (n > largest) largest = n;
    const size_t size = nih_task_roundup((size_t)n);
    if (!size) { ++failures; return 0; }
    size_t index = 0, capacity = 8;
    while (capacity < size) { ++index; capacity *= 2; }
    ++histogram[index];
    return (int)size;
}
static int init_mem(void *context) { (void)context; return nih_task_allocator_open(quota) ? SQLITE_NOMEM : SQLITE_OK; }
static void shutdown_mem(void *context) { (void)context; if (live_blocks || nih_task_allocator_close()) close_failed = 1; }
static const sqlite3_mem_methods methods = {
    alloc_mem, free_mem, resize_mem, size_mem, round_mem, init_mem, shutdown_mem, NULL
};
static int work(void) {
    sqlite3 *db = NULL;
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_initialize();
    if (rc != SQLITE_OK) return rc;
    rc = sqlite3_open(":memory:", &db);
    if (rc != SQLITE_OK) goto done;
    rc = sqlite3_prepare_v2(db, "SELECT 6*7", -1, &stmt, NULL);
    if (rc != SQLITE_OK) goto done;
    rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) goto done;
    if (sqlite3_column_int(stmt, 0) != 42) { rc = SQLITE_ERROR; goto done; }
    rc = sqlite3_finalize(stmt); stmt = NULL;
    if (rc != SQLITE_OK) goto done;
    rc = sqlite3_exec(db, "PRAGMA page_size=1024; CREATE TABLE t(id INTEGER PRIMARY KEY, value TEXT);"
                         "BEGIN; INSERT INTO t VALUES(1,'nihos'); INSERT INTO t VALUES(2,'zig'); COMMIT;", NULL, NULL, NULL);
    if (rc != SQLITE_OK) goto done;
    rc = sqlite3_prepare_v2(db, "SELECT count(*), sum(length(value)) FROM t", -1, &stmt, NULL);
    if (rc != SQLITE_OK) goto done;
    rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) goto done;
    if (sqlite3_column_int(stmt, 0) != 2 || sqlite3_column_int(stmt, 1) != 8) { rc = SQLITE_ERROR; goto done; }
    rc = SQLITE_OK;
done:
    if (stmt) sqlite3_finalize(stmt);
    if (db && sqlite3_close(db) != SQLITE_OK) abort();
    return rc;
}
int main(int argc, char **argv) {
    if (sqlite3_threadsafe() != 0) return 10;
    if (argc > 1) {
        char *end = NULL;
        unsigned long parsed = strtoul(argv[1], &end, 10);
        if (!end || *end || !parsed || parsed > 65535) return 9;
        quota = (size_t)parsed;
    }
    if (sqlite3_config(SQLITE_CONFIG_MALLOC, &methods) != SQLITE_OK ||
        sqlite3_config(SQLITE_CONFIG_LOOKASIDE, 0, 0) != SQLITE_OK) return 1;
    int rc = work();
    sqlite3_int64 used = -1, peak = -1;
    if (sqlite3_status64(SQLITE_STATUS_MEMORY_USED, &used, &peak, 0) != SQLITE_OK) return 2;
    const int baseline_attempts = attempts;
    printf("SQLite %s host rc=%d max_request=%d attempts=%d rejected=%d peak=%lld remaining=%lld\n",
           sqlite3_libversion(), rc, largest, attempts, failures, (long long)peak, (long long)used);
    printf("class_request_histogram:");
    for (size_t i = 0; i < 10; ++i) printf(" %d", histogram[i]);
    puts("");
    printf("class_peak_live quota=%zu:", quota);
    for (size_t i = 0; i < 10; ++i) printf(" %d", class_peak[i]);
    puts("");
    if (sqlite3_shutdown() != SQLITE_OK || close_failed || !nih_host_recovered()) return 3;
    if (rc != SQLITE_OK || used != 0 || failures) return 4;
    /* Fail each allocator call of the baseline, then retry the full workload.
     * SQLite may recover from transient OOM; both OK and NOMEM are valid. */
    for (int point = 0; point < baseline_attempts; ++point) {
        fail_after = point; attempts = 0; failures = 0; injected = 0;
        rc = work();
        if (injected != 1) return 11;
        if (rc != SQLITE_OK && rc != SQLITE_NOMEM) {
            fprintf(stderr, "unexpected injected OOM result point=%d rc=%d attempts=%d\n", point, rc, attempts);
            return 5;
        }
        if (sqlite3_shutdown() != SQLITE_OK || live_blocks || close_failed || !nih_host_recovered()) return 6;
        fail_after = -1; attempts = 0;
        if (work() != SQLITE_OK || sqlite3_shutdown() != SQLITE_OK || close_failed || !nih_host_recovered()) return 7;
    }
    if (nih_host_retire() || !nih_host_recovered()) return 8;
    printf("SQLite memory-only host PASS: %d injected OOM points, retry and full parent recovery\n", baseline_attempts);
    return 0;
}
