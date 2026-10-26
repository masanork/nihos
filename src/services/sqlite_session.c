/* Single-owner SQLite prototype; native execution is an opt-in boot fixture. */
#include "nihos_allocator.h"
#include "nihos_sqlite_session.h"
#include "sqlite3.h"
#include <stdatomic.h>

static _Atomic(uint32_t) owner, active, cancelled;
static atomic_flag entry = ATOMIC_FLAG_INIT;
static sqlite3 *connection;
static uint32_t serial, progress_calls, live_blocks;
static int pool_opened, allocator_fault;
#ifdef NIH_SQLITE_NATIVE_PROBE
_Static_assert(sizeof(void *) == 4, "native SQLite probe requires RV32");
volatile uint32_t nih_sqlite_open_execution_pc;
volatile uint32_t nih_sqlite_native_failed_size;
volatile uint32_t nih_sqlite_native_peak[10];
static uint32_t native_live[10];
static unsigned int native_class(size_t bytes) {
    unsigned int index = 0;
    for (size_t capacity = 8; capacity < bytes && index < 9; capacity *= 2) ++index;
    return index;
}
static void native_add(size_t bytes) {
    const unsigned int index = native_class(bytes);
    ++native_live[index];
    if (native_live[index] > nih_sqlite_native_peak[index]) nih_sqlite_native_peak[index] = native_live[index];
}
static void native_remove(size_t bytes) { --native_live[native_class(bytes)]; }
#endif
#ifdef NIH_SQLITE_TESTING
static int fail_after = -1, allocation_attempts, injected;
void nih_sqlite_test_fail_after(int point) { fail_after = point; allocation_attempts = 0; injected = 0; }
int nih_sqlite_test_attempts(void) { return allocation_attempts; }
int nih_sqlite_test_injected(void) { return injected; }
void nih_sqlite_test_near_token_exhaustion(void) { serial = UINT32_MAX - 1; }
#endif
static int fail_allocation(void) {
#ifdef NIH_SQLITE_TESTING
    const int point = allocation_attempts++;
    if (fail_after >= 0 && point == fail_after) { ++injected; return 1; }
#endif
    return 0;
}
static int owns(void) {
    const uint32_t current = nih_task_identity();
    return current != 0 && current == atomic_load_explicit(&owner, memory_order_acquire);
}
static void *allocate(int n) {
    if (n <= 0 || !owns() || fail_allocation()) return NULL;
    void *p = nih_task_malloc((size_t)n);
    if (p) ++live_blocks;
#ifdef NIH_SQLITE_NATIVE_PROBE
    if (p) native_add(nih_task_capacity(p));
    else nih_sqlite_native_failed_size = (uint32_t)n;
#endif
    return p;
}
static void release(void *p) {
    if (!p) return;
#ifdef NIH_SQLITE_NATIVE_PROBE
    const size_t bytes = nih_task_capacity(p);
#endif
    if (!owns() || !live_blocks || nih_task_free(p)) { allocator_fault = 1; return; }
    --live_blocks;
#ifdef NIH_SQLITE_NATIVE_PROBE
    native_remove(bytes);
#endif
}
static void *resize(void *p, int n) {
    if (n <= 0) { release(p); return NULL; }
    if (!owns() || fail_allocation()) return NULL;
#ifdef NIH_SQLITE_NATIVE_PROBE
    const size_t old_bytes = nih_task_capacity(p);
#endif
    void *next = nih_task_realloc(p, (size_t)n);
    if (next && !p) ++live_blocks;
#ifdef NIH_SQLITE_NATIVE_PROBE
    if (next) {
        const size_t bytes = nih_task_capacity(next);
        if (!p) native_add(bytes);
        else if (bytes != old_bytes) { native_add(bytes); native_remove(old_bytes); }
    } else nih_sqlite_native_failed_size = (uint32_t)n;
#endif
    return next;
}
static int size_of(void *p) { return owns() ? (int)nih_task_capacity(p) : 0; }
static int round_up(int n) { return n > 0 && owns() ? (int)nih_task_roundup((size_t)n) : 0; }
static int initialize_allocator(void *context) {
    (void)context;
    if (!owns()) return SQLITE_MISUSE;
    if (nih_task_allocator_open_profile(1)) return SQLITE_NOMEM;
    pool_opened = 1;
    return SQLITE_OK;
}
static void shutdown_allocator(void *context) {
    (void)context;
    if (!pool_opened) return;
    if (!owns() || live_blocks || nih_task_allocator_close()) { allocator_fault = 1; return; }
    pool_opened = 0;
}
static const sqlite3_mem_methods methods = {
    allocate, release, resize, size_of, round_up, initialize_allocator, shutdown_allocator, NULL
};
static void unlock(void) { atomic_flag_clear_explicit(&entry, memory_order_release); }
static int lock_owner(void) {
    const uint32_t current = nih_task_identity();
    const uint32_t expected = atomic_load_explicit(&owner, memory_order_acquire);
    if (!current || (expected && expected != current)) return NIH_SQLITE_OWNER;
    if (!expected) return NIH_SQLITE_STATE;
    if (atomic_flag_test_and_set_explicit(&entry, memory_order_acquire)) return NIH_SQLITE_BUSY;
    if (atomic_load_explicit(&owner, memory_order_relaxed) != current) { unlock(); return NIH_SQLITE_STATE; }
    if (allocator_fault || !connection) { unlock(); return NIH_SQLITE_STATE; }
    return 0;
}
uint32_t nih_sqlite_session_owner(void) { return atomic_load_explicit(&owner, memory_order_acquire); }
uint32_t nih_sqlite_session_active(void) { return atomic_load_explicit(&active, memory_order_acquire); }
int nih_sqlite_session_cancel(uint32_t token) {
    if (!token || token != atomic_load_explicit(&active, memory_order_acquire)) return NIH_SQLITE_STATE;
    atomic_store_explicit(&cancelled, token, memory_order_release);
    return 0;
}
static int progress(void *context) {
    (void)context;
    const uint32_t token = atomic_load_explicit(&active, memory_order_relaxed);
    return ++progress_calls >= 100000 || atomic_load_explicit(&cancelled, memory_order_acquire) == token;
}
static int authorize(void *context, int action, const char *one, const char *two, const char *database, const char *trigger) {
    (void)context; (void)one; (void)two; (void)database; (void)trigger;
    return action == SQLITE_PRAGMA || action == SQLITE_ATTACH || action == SQLITE_DETACH ? SQLITE_DENY : SQLITE_OK;
}
int nih_sqlite_session_open(void) {
#ifdef NIH_SQLITE_NATIVE_PROBE
    uint32_t pc;
    __asm__ volatile ("auipc %0,0" : "=r"(pc));
    nih_sqlite_open_execution_pc = pc;
#endif
    const uint32_t current = nih_task_identity();
    if (!current) return NIH_SQLITE_OWNER;
    if (atomic_flag_test_and_set_explicit(&entry, memory_order_acquire)) return NIH_SQLITE_BUSY;
    const uint32_t previous = atomic_load_explicit(&owner, memory_order_relaxed);
    if (previous) { unlock(); return previous == current ? NIH_SQLITE_STATE : NIH_SQLITE_OWNER; }
    atomic_store_explicit(&owner, current, memory_order_release);
    allocator_fault = 0;
    int rc = sqlite3_threadsafe() == 0 ? SQLITE_OK : SQLITE_MISUSE;
    if (rc == SQLITE_OK) rc = sqlite3_config(SQLITE_CONFIG_MALLOC, &methods);
    if (rc == SQLITE_OK) rc = sqlite3_config(SQLITE_CONFIG_LOOKASIDE, 0, 0);
    if (rc == SQLITE_OK) rc = sqlite3_initialize();
    if (rc == SQLITE_OK) rc = sqlite3_open(":memory:", &connection);
    if (rc == SQLITE_OK) {
        sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, 2048);
        sqlite3_limit(connection, SQLITE_LIMIT_SQL_LENGTH, 512);
        sqlite3_limit(connection, SQLITE_LIMIT_COLUMN, 16);
        sqlite3_limit(connection, SQLITE_LIMIT_EXPR_DEPTH, 16);
        sqlite3_limit(connection, SQLITE_LIMIT_COMPOUND_SELECT, 4);
        sqlite3_limit(connection, SQLITE_LIMIT_VARIABLE_NUMBER, 16);
        sqlite3_limit(connection, SQLITE_LIMIT_ATTACHED, 0);
        rc = sqlite3_exec(connection, "PRAGMA page_size=1024; PRAGMA max_page_count=16;", NULL, NULL, NULL);
        if (rc == SQLITE_OK) rc = sqlite3_db_config(connection, SQLITE_DBCONFIG_DEFENSIVE, 1, NULL);
        if (rc == SQLITE_OK) rc = sqlite3_db_config(connection, SQLITE_DBCONFIG_TRUSTED_SCHEMA, 0, NULL);
        if (rc == SQLITE_OK) rc = sqlite3_set_authorizer(connection, authorize, NULL);
    }
    if (rc != SQLITE_OK) {
        if (connection) {
            if (sqlite3_close(connection) != SQLITE_OK) allocator_fault = 1;
            else connection = NULL;
        }
        if (sqlite3_shutdown() != SQLITE_OK) allocator_fault = 1;
        if (!allocator_fault && !pool_opened && !connection && !live_blocks)
            atomic_store_explicit(&owner, 0, memory_order_release);
    }
    if (allocator_fault) rc = NIH_SQLITE_STATE;
    unlock();
    return rc;
}
static int whitespace(char byte) { return byte == ' ' || byte == '\t' || byte == '\n' || byte == '\r'; }
int nih_sqlite_session_eval(const char *sql, size_t length, struct nih_sqlite_result *result) {
    int rc = lock_owner();
    if (rc) return rc;
    if (!sql || !result || !length || length > 512 || serial == UINT32_MAX) { unlock(); return NIH_SQLITE_LIMIT; }
    *result = (struct nih_sqlite_result){ 0, 0 };
    progress_calls = 0;
    atomic_store_explicit(&active, ++serial, memory_order_release);
    sqlite3_progress_handler(connection, 100, progress, NULL);
    sqlite3_stmt *statement = NULL;
    const char *tail = NULL;
    rc = sqlite3_prepare_v2(connection, sql, (int)length, &statement, &tail);
    if (rc == SQLITE_OK && !statement) rc = NIH_SQLITE_LIMIT;
    if (rc == SQLITE_OK && !tail) rc = NIH_SQLITE_LIMIT;
    if (rc == SQLITE_OK) {
        while (tail < sql + length && whitespace(*tail)) ++tail;
        if (tail != sql + length || sqlite3_column_count(statement) > 1 ||
            (!sqlite3_stmt_readonly(statement) && sqlite3_column_count(statement))) rc = NIH_SQLITE_LIMIT;
    }
    struct nih_sqlite_result value = { 0, 0 };
    if (rc == SQLITE_OK) {
        rc = sqlite3_step(statement);
        if (rc == SQLITE_ROW) {
            const int type = sqlite3_column_type(statement, 0);
            if (type != SQLITE_INTEGER && type != SQLITE_NULL) rc = NIH_SQLITE_LIMIT;
            else {
                value.has_value = (uint32_t)(type == SQLITE_INTEGER);
                if (value.has_value) value.value = sqlite3_column_int64(statement, 0);
                rc = sqlite3_step(statement);
                if (rc == SQLITE_ROW) rc = NIH_SQLITE_LIMIT;
            }
        }
        if (rc == SQLITE_DONE) rc = SQLITE_OK;
    }
    if (statement) {
        const int final = sqlite3_finalize(statement);
        if (rc == SQLITE_OK && final != SQLITE_OK) rc = final;
    }
    sqlite3_progress_handler(connection, 0, NULL, NULL);
    atomic_store_explicit(&active, 0, memory_order_release);
    if (allocator_fault) rc = NIH_SQLITE_STATE;
    if (rc == SQLITE_OK) *result = value;
    unlock();
    return rc;
}
int nih_sqlite_session_close(void) {
    int rc = lock_owner();
    if (rc) return rc;
    rc = sqlite3_close(connection);
    if (rc == SQLITE_OK) {
        connection = NULL;
        rc = sqlite3_shutdown();
        if (allocator_fault || pool_opened || live_blocks) rc = NIH_SQLITE_STATE;
        if (rc == SQLITE_OK) atomic_store_explicit(&owner, 0, memory_order_release);
    }
    unlock();
    return rc;
}
