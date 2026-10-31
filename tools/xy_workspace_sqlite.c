/* macOS SQLite adapter for the bounded xy source-store contract. */
#include "nihos_xy_workspace.h"
#include <sqlite3.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct XyWorkspaceStore { sqlite3 *db; char error[256]; int ready; };
static int fail(XyWorkspaceStore *s, const char *message) {
    snprintf(s->error, sizeof(s->error), "%s", message);
    return -1;
}
static int sql(XyWorkspaceStore *s, const char *text) {
    if (sqlite3_exec(s->db, text, NULL, NULL, NULL) != SQLITE_OK)
        return fail(s, sqlite3_errmsg(s->db));
    return 0;
}
static int scalar(XyWorkspaceStore *s, const char *text, int64_t *out) {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(s->db, text, -1, &stmt, NULL) != SQLITE_OK)
        return fail(s, sqlite3_errmsg(s->db));
    int step = sqlite3_step(stmt);
    if (step == SQLITE_ROW) *out = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return step == SQLITE_ROW ? 0 : fail(s, "Missing workspace metadata");
}
XyWorkspaceStore *xy_workspace_open(const char *path) {
    XyWorkspaceStore *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    if (sqlite3_open_v2(path, &s->db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX, NULL) != SQLITE_OK) {
        fail(s, sqlite3_errmsg(s->db));
        return s;
    }
    sqlite3_busy_timeout(s->db, 250);
    int64_t app = 0, version = 0, tables = 0;
    if (scalar(s, "PRAGMA application_id", &app) || scalar(s, "PRAGMA user_version", &version) ||
        scalar(s, "SELECT count(*) FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'", &tables)) return s;
    if ((app != 0x58595753 || version != 1) && (app != 0 || version != 0 || tables != 0)) {
        fail(s, "Unsupported workspace database or schema version"); return s;
    }
    if (sql(s, "PRAGMA foreign_keys=ON") || sql(s, "PRAGMA synchronous=FULL")) return s;
    if (app == 0 && sql(s,
        "BEGIN IMMEDIATE;"
        "CREATE TABLE xy_source_revisions("
        "revision INTEGER PRIMARY KEY AUTOINCREMENT,"
        "source BLOB NOT NULL CHECK(length(source)<=4096),"
        "created_at TEXT NOT NULL DEFAULT(strftime('%Y-%m-%dT%H:%M:%fZ','now')));"
        "CREATE TABLE xy_workspace_head(id INTEGER PRIMARY KEY CHECK(id=1),"
        "revision INTEGER REFERENCES xy_source_revisions(revision));"
        "INSERT INTO xy_workspace_head VALUES(1,NULL);"
        "PRAGMA application_id=1482250067;PRAGMA user_version=1;COMMIT;")) {
        sqlite3_exec(s->db, "ROLLBACK", NULL, NULL, NULL);
        return s;
    }
    s->ready = 1;
    return s;
}
void xy_workspace_close(XyWorkspaceStore *s) {
    if (!s) return;
    if (s->db) sqlite3_close(s->db);
    free(s);
}
const char *xy_workspace_error(XyWorkspaceStore *s) { return s ? s->error : "Cannot allocate workspace store"; }
static int head(XyWorkspaceStore *s, int64_t *out) {
    return scalar(s, "SELECT coalesce(revision,0) FROM xy_workspace_head WHERE id=1", out);
}
int32_t xy_workspace_load(XyWorkspaceStore *s, int64_t revision, uint8_t *out, uint32_t capacity, int64_t *out_revision) {
    if (!s || !s->ready || !out_revision || revision < 0) return -1;
    *out_revision = 0;
    if (revision == 0 && head(s, &revision)) return -1;
    if (revision == 0) return 0;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(s->db, "SELECT source FROM xy_source_revisions WHERE revision=?1", -1, &stmt, NULL) != SQLITE_OK)
        return fail(s, sqlite3_errmsg(s->db));
    int result = -1;
    if (sqlite3_bind_int64(stmt, 1, revision) != SQLITE_OK) fail(s, sqlite3_errmsg(s->db));
    else if (sqlite3_step(stmt) != SQLITE_ROW) fail(s, "Source revision not found");
    else {
        int length = sqlite3_column_bytes(stmt, 0);
        const void *bytes = sqlite3_column_blob(stmt, 0);
        if (length > XY_SOURCE_LIMIT || (uint32_t)length > capacity || (length && (!out || !bytes))) fail(s, "Source exceeds buffer capacity");
        else {
            if (length) memcpy(out, bytes, (size_t)length);
            *out_revision = revision;
            result = length;
        }
    }
    sqlite3_finalize(stmt);
    return result;
}
static int begin_change(XyWorkspaceStore *s, int64_t expected) {
    if (sql(s, "BEGIN IMMEDIATE")) return -1;
    int64_t current = 0;
    if (head(s, &current)) { sqlite3_exec(s->db, "ROLLBACK", NULL, NULL, NULL); return -1; }
    if (current != expected) {
        sqlite3_exec(s->db, "ROLLBACK", NULL, NULL, NULL);
        return fail(s, "Workspace changed in another session; reload before saving");
    }
    return 0;
}
static int update_head(XyWorkspaceStore *s, int64_t revision) {
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(s->db, "UPDATE xy_workspace_head SET revision=?1 WHERE id=1", -1, &stmt, NULL) != SQLITE_OK)
        return fail(s, sqlite3_errmsg(s->db));
    int ok = sqlite3_bind_int64(stmt, 1, revision) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_DONE && sqlite3_changes(s->db) == 1;
    sqlite3_finalize(stmt);
    return ok ? 0 : fail(s, sqlite3_errmsg(s->db));
}
static int rollback(XyWorkspaceStore *s) {
    sqlite3_exec(s->db, "ROLLBACK", NULL, NULL, NULL);
    return -1;
}
int32_t xy_workspace_save(XyWorkspaceStore *s, const uint8_t *source, uint32_t length, int64_t expected, int64_t *out_revision) {
    if (!s || !s->ready || !out_revision) return -1;
    *out_revision = 0;
    if (length > XY_SOURCE_LIMIT || (length && (!source || memchr(source, 0, length)))) return fail(s, "Invalid source length or embedded NUL");
    if (begin_change(s, expected)) return -1;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(s->db, "INSERT INTO xy_source_revisions(source) VALUES(?1)", -1, &stmt, NULL) != SQLITE_OK) {
        fail(s, sqlite3_errmsg(s->db)); return rollback(s);
    }
    const uint8_t empty = 0;
    int ok = sqlite3_bind_blob(stmt, 1, source ? source : &empty, (int)length, SQLITE_TRANSIENT) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_DONE;
    sqlite3_finalize(stmt);
    if (!ok) { fail(s, sqlite3_errmsg(s->db)); return rollback(s); }
    int64_t revision = sqlite3_last_insert_rowid(s->db);
    if (update_head(s, revision) || sql(s, "COMMIT")) return rollback(s);
    *out_revision = revision;
    return 0;
}
int32_t xy_workspace_select(XyWorkspaceStore *s, int64_t revision, int64_t expected) {
    if (!s || !s->ready || revision <= 0) return -1;
    if (begin_change(s, expected)) return -1;
    if (update_head(s, revision) || sql(s, "COMMIT")) return rollback(s);
    return 0;
}
int32_t xy_workspace_history(XyWorkspaceStore *s, int64_t *out, uint32_t capacity) {
    if (!s || !s->ready || !out || capacity > XY_HISTORY_LIMIT) return -1;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(s->db, "SELECT revision FROM xy_source_revisions ORDER BY revision DESC LIMIT ?1", -1, &stmt, NULL) != SQLITE_OK)
        return fail(s, sqlite3_errmsg(s->db));
    if (sqlite3_bind_int(stmt, 1, (int)capacity) != SQLITE_OK) { sqlite3_finalize(stmt); return fail(s, "Cannot bind history limit"); }
    int count = 0, step;
    while ((step = sqlite3_step(stmt)) == SQLITE_ROW) out[count++] = sqlite3_column_int64(stmt, 0);
    sqlite3_finalize(stmt);
    return step == SQLITE_DONE ? count : fail(s, sqlite3_errmsg(s->db));
}
