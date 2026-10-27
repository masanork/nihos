/* Actual SQLite over the copy-mailbox/checkpoint VFS. Host allocator only. */
#include "sqlite3.h"
#include "store_bridge.h"
#include <stdio.h>
#include <string.h>
static sqlite3_int64 peak;
static int observed_error;
unsigned long long nih_sqlite_peak(void) {
    sqlite3_int64 current = sqlite3_memory_highwater(0);
    return (unsigned long long)(current > peak ? current : peak);
}
int nih_sqlite_observed_error(void) { return observed_error; }
const char *nih_sqlite_version(void) { return sqlite3_libversion(); }
static int exec(sqlite3 *db, const char *sql) {
    char *message = 0;
    int rc = sqlite3_exec(db, sql, 0, 0, &message);
    if (rc) observed_error = rc;
    if (rc) fprintf(stderr, "SQL rc=%d extended=%d message=%s sql=%s\n", rc, sqlite3_extended_errcode(db), message ? message : "", sql);
    sqlite3_free(message);
    return rc;
}
static int scalar(sqlite3 *db, const char *sql, sqlite3_int64 expected) {
    sqlite3_stmt *stmt = 0;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, 0) != SQLITE_OK) return 1;
    int good = sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_int64(stmt, 0) == expected && sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
    if (!good) fprintf(stderr, "SCALAR_MISMATCH sql=%s expected=%lld\n", sql, (long long)expected);
    return !good;
}
static int integrity(sqlite3 *db) {
    sqlite3_stmt *stmt = 0;
    if (sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &stmt, 0) != SQLITE_OK) return 1;
    int rc = sqlite3_step(stmt);
    const unsigned char *text = rc == SQLITE_ROW ? sqlite3_column_text(stmt, 0) : 0;
    int good = text && !strcmp((const char *)text, "ok");
    sqlite3_finalize(stmt); return !good;
}
int nih_sqlite_store_run(const char *command) {
    if (sqlite3_threadsafe() != 0 || !sqlite3_compileoption_used("OMIT_WAL") || sqlite3_initialize() != SQLITE_OK) return 1;
    sqlite3 *db = 0;
    int rc = sqlite3_open_v2("/main.db", &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, "nihos-store-host");
    if (rc != SQLITE_OK) { fprintf(stderr, "OPEN rc=%d message=%s\n", rc, db ? sqlite3_errmsg(db) : ""); sqlite3_close(db); return 2; }
    int fail = exec(db, "PRAGMA page_size=4096; PRAGMA journal_mode=PERSIST; PRAGMA synchronous=FULL; PRAGMA temp_store=MEMORY; PRAGMA cache_size=8; PRAGMA max_page_count=64;");
    if (!fail) fail = scalar(db, "PRAGMA page_size", 4096) || scalar(db, "PRAGMA synchronous", 2);
    if (!fail) {
        sqlite3_stmt *s = 0;
        if (sqlite3_prepare_v2(db, "PRAGMA journal_mode", -1, &s, 0) != SQLITE_OK || sqlite3_step(s) != SQLITE_ROW || !sqlite3_column_text(s, 0) || strcmp((const char *)sqlite3_column_text(s, 0), "persist")) fail = 3;
        sqlite3_finalize(s);
    }
    if (!fail && nih_store_vfs_selftest()) fail = 4;
    if (!fail && !strcmp(command, "seed")) {
        fail = exec(db, "BEGIN; CREATE TABLE records(id INTEGER PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL); CREATE TABLE marker(version INTEGER NOT NULL); INSERT INTO marker VALUES(0); WITH RECURSIVE n(x) AS(VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<64) INSERT INTO records SELECT x,0,zeroblob(1000) FROM n; COMMIT;");
    } else if (!fail && (!strcmp(command, "verify-old") || !strcmp(command, "verify-new"))) {
        int version = !strcmp(command, "verify-new");
        fail = scalar(db, "SELECT count(*) FROM records", 64) || scalar(db, "SELECT sum(version) FROM records", 64 * version) || scalar(db, "SELECT version FROM marker", version) || integrity(db);
    } else if (!fail && !strcmp(command, "quota-full")) {
        rc = exec(db, "BEGIN; INSERT INTO records VALUES(1000,9,zeroblob(524288)); COMMIT;");
        if ((rc & 255) != SQLITE_FULL) fail = 5;
        if (!sqlite3_get_autocommit(db)) (void)exec(db, "ROLLBACK");
        fail |= scalar(db, "SELECT count(*) FROM records", 64) || scalar(db, "SELECT sum(version) FROM records", 0) || integrity(db);
    } else if (!fail && !strcmp(command, "rollback")) {
        fail = exec(db, "BEGIN IMMEDIATE; UPDATE records SET version=9; UPDATE marker SET version=9; ROLLBACK;") || scalar(db, "SELECT sum(version) FROM records", 0) || scalar(db, "SELECT version FROM marker", 0) || integrity(db);
    } else if (!fail && (!strcmp(command, "update") || !strcmp(command, "db-sync-wait") || !strcmp(command, "journal-sync-wait") || !strcmp(command, "commit-wait") || !strcmp(command, "sync-error"))) {
        rc = exec(db, "BEGIN IMMEDIATE; UPDATE records SET version=1; UPDATE marker SET version=1; COMMIT;");
        if (!strcmp(command, "sync-error")) {
            if ((rc & 255) != SQLITE_IOERR) fail = 6;
        } else fail = rc || scalar(db, "SELECT sum(version) FROM records", 64) || scalar(db, "SELECT version FROM marker", 1) || integrity(db);
    } else if (!fail) fail = 7;
    peak = sqlite3_memory_highwater(0);
    fprintf(stderr, "SQLITE_STORE_RESULT version=%s rc=%d sqlite_peak_bytes=%lld cache_page_bytes=4096\n", sqlite3_libversion(), fail, (long long)sqlite3_memory_highwater(0));
    int close_rc = sqlite3_close(db);
    if (!fail && close_rc != SQLITE_OK) fail = 8;
    if (!fail && sqlite3_shutdown() != SQLITE_OK) fail = 9;
    fflush(stderr);
    return fail;
}
