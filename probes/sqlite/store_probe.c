/* Actual SQLite over the copy-mailbox/checkpoint VFS. Host allocator only. */
#include "sqlite3.h"
#include "store_bridge.h"
#include <stdio.h>
#include <string.h>
#ifdef NIH_SQLITE_CACHE_EXPERIMENT
#include "store_allocator.h"
#endif
static sqlite3_int64 peak;
static int observed_error, checked_version = -1, committed;
int nih_sqlite_committed(void) { return committed; }
int nih_sqlite_checked_version(void) { return checked_version; }
unsigned long long nih_sqlite_peak(void) {
    sqlite3_int64 current = sqlite3_memory_highwater(0);
    return (unsigned long long)(current > peak ? current : peak);
}
int nih_sqlite_observed_error(void) { return observed_error; }
const char *nih_sqlite_version(void) { return sqlite3_libversion(); }
int nih_sqlite_failure_cleanup(void) {
    int rc = sqlite3_shutdown();
#ifdef NIH_SQLITE_CACHE_EXPERIMENT
    if (!nih_store_memory_shutdown_ok()) return 1;
#endif
    return rc != SQLITE_OK;
}
static void remember(int rc) {
    if (rc != SQLITE_OK && rc != SQLITE_ROW && rc != SQLITE_DONE) observed_error = rc;
}
static int exec(sqlite3 *db, const char *sql) {
    char *message = 0;
    int rc = sqlite3_exec(db, sql, 0, 0, &message);
    if (strstr(sql, "COMMIT;")) committed = rc == SQLITE_OK;
    if (rc) observed_error = rc;
    if (rc) fprintf(stderr, "SQL rc=%d extended=%d message=%s sql=%s\n", rc, sqlite3_extended_errcode(db), message ? message : "", sql);
    sqlite3_free(message);
    return rc;
}
static int scalar(sqlite3 *db, const char *sql, sqlite3_int64 expected) {
    sqlite3_stmt *stmt = 0;
    int rc = sqlite3_prepare_v2(db, sql, -1, &stmt, 0);
    if (rc != SQLITE_OK) { remember(rc); return 1; }
    rc = sqlite3_step(stmt); remember(rc);
    int good = rc == SQLITE_ROW && sqlite3_column_int64(stmt, 0) == expected;
    if (good) { rc = sqlite3_step(stmt); remember(rc); good = rc == SQLITE_DONE; }
    sqlite3_finalize(stmt);
    if (!good) fprintf(stderr, "SCALAR_MISMATCH sql=%s expected=%lld\n", sql, (long long)expected);
    return !good;
}
static int integrity(sqlite3 *db) {
    sqlite3_stmt *stmt = 0;
    int rc = sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &stmt, 0);
    if (rc != SQLITE_OK) { remember(rc); return 1; }
    rc = sqlite3_step(stmt); remember(rc);
    const unsigned char *text = rc == SQLITE_ROW ? sqlite3_column_text(stmt, 0) : 0;
    int good = text && !strcmp((const char *)text, "ok");
    if (!good) remember(sqlite3_errcode(db));
    sqlite3_finalize(stmt); return !good;
}
#ifdef NIH_SQLITE_CACHE_EXPERIMENT
static int allocator_edges(void) {
    int fail = 0;
    unsigned char *p = sqlite3_malloc(2048), *blocker = sqlite3_malloc(8192), *next = NULL;
    if (!p || !blocker || !nih_store_allocator_is_bounded()) { fail = 1; goto done; }
    memset(p, 0xa5, 2048);
    next = sqlite3_realloc(p, 8192);
    if (next) { p = next; fail = 1; goto done; }
    for (int i = 0; i < 2048; ++i) if (p[i] != 0xa5) { fail = 1; goto done; }
    sqlite3_free(blocker); blocker = NULL;
    next = sqlite3_realloc(p, 8192);
    if (!next) { fail = 1; goto done; }
    p = next;
    for (int i = 0; i < 2048; ++i) if (p[i] != 0xa5) { fail = 1; goto done; }
    blocker = sqlite3_malloc(8192);
    if (blocker || sqlite3_msize(p) != 8192) fail = 1;
 done:
    sqlite3_free(blocker); sqlite3_free(p);
    return fail;
}
#endif
int nih_sqlite_store_run(const char *command) {
    if (sqlite3_threadsafe() != 0 || !sqlite3_compileoption_used("OMIT_WAL")) return 1;
    int init_rc = sqlite3_initialize();
    if (init_rc != SQLITE_OK) { remember(init_rc); return 1; }
    int rows = 64;
#ifdef NIH_SQLITE_CACHE_EXPERIMENT
    rows = nih_store_rows();
#endif
    sqlite3 *db = 0;
    int rc = sqlite3_open_v2("/main.db", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, "nihos-store-host");
    if (rc != SQLITE_OK) { remember(rc); fprintf(stderr, "OPEN rc=%d message=%s\n", rc, db ? sqlite3_errmsg(db) : ""); sqlite3_close(db); return 2; }
    int fail = exec(db, "PRAGMA page_size=4096; PRAGMA journal_mode=PERSIST; PRAGMA synchronous=FULL; PRAGMA temp_store=MEMORY; PRAGMA cache_size=8; PRAGMA max_page_count=64;");
#ifdef NIH_SQLITE_CACHE_EXPERIMENT
    if (!fail) {
        char pragma[80];
        (void)snprintf(pragma, sizeof(pragma), "PRAGMA cache_size=%d; PRAGMA max_page_count=%d;", nih_store_allocator_is_bounded() ? nih_store_cache_pages() : -nih_store_cache_kib(), rows > 64 ? 512 : 64);
        fail = exec(db, pragma);
        if (!fail) fail = scalar(db, "PRAGMA cache_size", nih_store_allocator_is_bounded() ? nih_store_cache_pages() : -nih_store_cache_kib());
    }
#endif
    if (!fail) fail = scalar(db, "PRAGMA page_size", 4096) || scalar(db, "PRAGMA synchronous", 2);
    if (!fail) {
        sqlite3_stmt *s = 0;
        if (sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &s, 0) != SQLITE_OK || sqlite3_step(s) != SQLITE_ROW || !sqlite3_column_text(s, 0) || strcmp((const char *)sqlite3_column_text(s, 0), "persist")) { remember(sqlite3_errcode(db)); fail = 3; }
        sqlite3_finalize(s);
    }
    if (!fail && nih_store_vfs_selftest()) fail = 4;
    if (!fail && !strcmp(command, "seed")) {
        char sql[512];
        int n = snprintf(sql, sizeof(sql), "BEGIN; CREATE TABLE records(id INTEGER PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL); CREATE TABLE marker(version INTEGER NOT NULL); INSERT INTO marker VALUES(0); WITH RECURSIVE n(x) AS(VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<%d) INSERT INTO records SELECT x,0,zeroblob(1000) FROM n; COMMIT;", rows);
        fail = n < 0 || (size_t)n >= sizeof(sql) ? SQLITE_ERROR : exec(db, sql);
    } else if (!fail && (!strcmp(command, "verify-old") || !strcmp(command, "verify-new") || !strcmp(command, "verify-either"))) {
        int version = !strcmp(command, "verify-new");
        if (!strcmp(command, "verify-either")) {
            sqlite3_stmt *s = 0;
            rc = sqlite3_prepare_v2(db, "SELECT version FROM marker", -1, &s, 0);
            if (rc == SQLITE_OK) rc = sqlite3_step(s);
            if (rc != SQLITE_ROW) { remember(rc); sqlite3_finalize(s); sqlite3_close(db); sqlite3_shutdown(); return 11; }
            version = sqlite3_column_int(s, 0); sqlite3_finalize(s);
            if (version != 0 && version != 1) { sqlite3_close(db); sqlite3_shutdown(); return 12; }
        }
        checked_version = version;
        fail = scalar(db, "SELECT count(*) FROM records", rows) || scalar(db, "SELECT sum(version) FROM records", rows * version) || scalar(db, "SELECT version FROM marker", version) || integrity(db);
#ifdef NIH_SQLITE_CACHE_EXPERIMENT
    } else if (!fail && !strcmp(command, "allocator-selftest")) {
        fail = allocator_edges();
#endif
    } else if (!fail && !strcmp(command, "quota-full")) {
        rc = exec(db, rows > 64 ? "BEGIN; INSERT INTO records VALUES(1000,9,zeroblob(4194304)); COMMIT;" : "BEGIN; INSERT INTO records VALUES(1000,9,zeroblob(524288)); COMMIT;");
        if ((rc & 255) != SQLITE_FULL) fail = 5;
        if (!sqlite3_get_autocommit(db)) (void)exec(db, "ROLLBACK");
        fail |= scalar(db, "SELECT count(*) FROM records", rows) || scalar(db, "SELECT sum(version) FROM records", 0) || integrity(db);
    } else if (!fail && !strcmp(command, "rollback")) {
        fail = exec(db, "BEGIN IMMEDIATE; UPDATE records SET version=9; UPDATE marker SET version=9; ROLLBACK;") || scalar(db, "SELECT sum(version) FROM records", 0) || scalar(db, "SELECT version FROM marker", 0) || integrity(db);
    } else if (!fail && (!strcmp(command, "update") || !strcmp(command, "db-sync-wait") || !strcmp(command, "journal-sync-wait") || !strcmp(command, "commit-wait") || !strcmp(command, "sync-error"))) {
        rc = exec(db, "BEGIN IMMEDIATE; UPDATE records SET version=1; UPDATE marker SET version=1; COMMIT;");
        if (!strcmp(command, "sync-error")) {
            if ((rc & 255) != SQLITE_IOERR) fail = 6;
        } else fail = rc || scalar(db, "SELECT sum(version) FROM records", rows) || scalar(db, "SELECT version FROM marker", 1) || integrity(db);
    } else if (!fail) fail = 7;
    peak = sqlite3_memory_highwater(0);
    fprintf(stderr, "SQLITE_STORE_RESULT version=%s rc=%d sqlite_peak_bytes=%lld cache_page_bytes=4096\n", sqlite3_libversion(), fail, (long long)sqlite3_memory_highwater(0));
    int close_rc = sqlite3_close(db);
    if (!fail && close_rc != SQLITE_OK) fail = 8;
    int shutdown_rc = sqlite3_shutdown();
    if (!fail && shutdown_rc != SQLITE_OK) fail = 9;
#ifdef NIH_SQLITE_CACHE_EXPERIMENT
    if (!nih_store_memory_shutdown_ok()) fail = 10;
#endif
    fflush(stderr);
    return fail;
}
