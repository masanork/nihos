#include "nihos_allocator.h"
#include "nihos_sqlite_session.h"
#include "sqlite3.h"
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
int nih_host_select(uint16_t slot);
int nih_host_retire(void);
int nih_host_recovered(void);
#define REQUIRE(condition) do { if (!(condition)) { fprintf(stderr, "session check failed line=%d\n", __LINE__); return 1; } } while (0)
static int eval(const char *sql, int64_t *value) {
    struct nih_sqlite_result result = { 0, 0 };
    const int rc = nih_sqlite_session_eval(sql, strlen(sql), &result);
    if (value && !rc) *value = result.has_value ? result.value : 0;
    return rc;
}
static int workload(void) {
    int rc = nih_sqlite_session_open();
    if (rc) return rc;
    int64_t value = 0;
    rc = eval("SELECT 6*7", &value);
    if (!rc && value != 42) return SQLITE_ERROR;
    if (!rc) rc = eval("CREATE TABLE t(v INTEGER)", NULL);
    if (!rc) rc = eval("BEGIN", NULL);
    if (!rc) rc = eval("INSERT INTO t VALUES(7)", NULL);
    if (!rc) rc = eval("ROLLBACK", NULL);
    if (!rc) rc = eval("SELECT count(*) FROM t", &value);
    if (!rc && value != 0) return SQLITE_ERROR;
    if (!rc) rc = eval("INSERT INTO t VALUES(3)", NULL);
    if (!rc) rc = eval("SELECT sum(v) FROM t", &value);
    if (!rc && value != 3) return SQLITE_ERROR;
    const int closed = nih_sqlite_session_close();
    return rc ? rc : closed;
}
struct cancellation {
    _Atomic(int) ready, finished;
    int wrong_owner, cancel_result;
    uint32_t token;
};
static void *cancel_peer(void *argument) {
    struct cancellation *state = argument;
    state->wrong_owner = nih_host_select(1) ? 1 : eval("SELECT 1", NULL);
    atomic_store(&state->ready, 1);
    while (!(state->token = nih_sqlite_session_active())) {
        if (atomic_load(&state->finished)) return NULL;
        sched_yield();
    }
    state->cancel_result = nih_sqlite_session_cancel(state->token);
    return NULL;
}
int main(void) {
    const uint32_t original = nih_task_identity();
    REQUIRE(original && nih_sqlite_session_close() == NIH_SQLITE_STATE);
    REQUIRE(nih_task_allocator_open(2) == 0);
    void *existing = nih_task_malloc(13);
    REQUIRE(existing && nih_sqlite_session_open() == SQLITE_NOMEM);
    REQUIRE(nih_task_capacity(existing) == 16 && nih_sqlite_session_owner() == 0);
    REQUIRE(!nih_task_free(existing) && !nih_task_allocator_close() && nih_host_recovered());
    nih_sqlite_test_fail_after(-1);
    REQUIRE(workload() == 0 && nih_host_recovered());
    const int points = nih_sqlite_test_attempts();
    REQUIRE(points > 0);
    for (int point = 0; point < points; ++point) {
        nih_sqlite_test_fail_after(point);
        const int rc = workload();
        if (rc != 0 && rc != SQLITE_NOMEM) fprintf(stderr, "unexpected OOM point=%d rc=%d\n", point, rc);
        REQUIRE((rc == 0 || rc == SQLITE_NOMEM) && nih_sqlite_test_injected() == 1);
        REQUIRE(nih_sqlite_session_owner() == 0 && nih_host_recovered());
        nih_sqlite_test_fail_after(-1);
        REQUIRE(workload() == 0 && nih_host_recovered());
    }
    REQUIRE(nih_sqlite_session_open() == 0);
    REQUIRE(nih_sqlite_session_open() == NIH_SQLITE_STATE);
    REQUIRE(nih_sqlite_session_owner() == original);
    REQUIRE(!nih_host_select(1));
    REQUIRE(nih_sqlite_session_open() == NIH_SQLITE_OWNER);
    REQUIRE(eval("SELECT 1", NULL) == NIH_SQLITE_OWNER);
    REQUIRE(nih_sqlite_session_close() == NIH_SQLITE_OWNER);
    REQUIRE(!nih_host_select(0));
    struct nih_sqlite_result result = { 99, 1 };
    REQUIRE(nih_sqlite_session_eval("x", 513, &result) == NIH_SQLITE_LIMIT);
    REQUIRE(eval("SELECT 1; SELECT 2", NULL) == NIH_SQLITE_LIMIT);
    REQUIRE(nih_sqlite_session_eval("SELECT 1\0SELECT 2", 17, &result) == NIH_SQLITE_LIMIT);
    REQUIRE(nih_sqlite_session_eval("SELECT 1 UNION ALL SELECT 2", sizeof("SELECT 1 UNION ALL SELECT 2") - 1, &result) == NIH_SQLITE_LIMIT && !result.has_value);
    REQUIRE(eval("SELECT 'text'", NULL) == NIH_SQLITE_LIMIT);
    REQUIRE(eval("SELECT 1,2", NULL) == NIH_SQLITE_LIMIT);
    REQUIRE(eval("SELECT NULL", NULL) == 0);
    REQUIRE(eval("PRAGMA max_page_count=1000000", NULL) == SQLITE_AUTH);
    REQUIRE(eval("ATTACH ':memory:' AS other", NULL) == SQLITE_AUTH);
    REQUIRE(eval("CREATE TABLE t(v INTEGER)", NULL) == 0);
    REQUIRE(eval("INSERT INTO t VALUES(9) RETURNING v", NULL) == NIH_SQLITE_LIMIT);
    int64_t count = -1;
    REQUIRE(eval("SELECT count(*) FROM t", &count) == 0 && count == 0);
    const char *long_query = "WITH RECURSIVE n(v) AS (VALUES(0) UNION ALL SELECT v+1 FROM n WHERE v<100000000) SELECT sum(v) FROM n";
    const int budget_rc = eval(long_query, NULL);
    REQUIRE(budget_rc == SQLITE_INTERRUPT);
    struct cancellation cancelled = { .cancel_result = NIH_SQLITE_STATE };
    pthread_t peer;
    REQUIRE(pthread_create(&peer, NULL, cancel_peer, &cancelled) == 0);
    while (!atomic_load(&cancelled.ready)) sched_yield();
    REQUIRE(eval(long_query, NULL) == SQLITE_INTERRUPT);
    atomic_store(&cancelled.finished, 1);
    REQUIRE(pthread_join(peer, NULL) == 0);
    REQUIRE(cancelled.wrong_owner == NIH_SQLITE_OWNER && cancelled.token && cancelled.cancel_result == 0);
    REQUIRE(nih_sqlite_session_active() == 0 && nih_sqlite_session_cancel(cancelled.token) == NIH_SQLITE_STATE);
    REQUIRE(eval("SELECT 42", &count) == 0 && count == 42);
    REQUIRE(nih_sqlite_session_close() == 0 && nih_host_recovered());
    REQUIRE(workload() == 0 && nih_host_recovered());
    nih_sqlite_test_near_token_exhaustion();
    REQUIRE(nih_sqlite_session_open() == 0);
    REQUIRE(eval("SELECT 42", &count) == 0 && count == 42);
    REQUIRE(eval("SELECT 42", &count) == NIH_SQLITE_LIMIT);
    REQUIRE(nih_sqlite_session_close() == 0 && nih_host_recovered());
    /* Final fail-stop case: retirement reclaims memory, but never authorizes a
     * new generation to touch old global SQLite pointers. Restart is required. */
    REQUIRE(nih_sqlite_session_open() == 0 && nih_host_retire() == 0);
    REQUIRE(nih_task_identity() != original && nih_host_recovered());
    REQUIRE(eval("SELECT 1", NULL) == NIH_SQLITE_OWNER);
    REQUIRE(nih_sqlite_session_open() == NIH_SQLITE_OWNER && nih_sqlite_session_close() == NIH_SQLITE_OWNER);
    printf("SQLite owner session host PASS: %d OOM points, quotas=64KiB, ownership, bounds, VM budget, pthread cancel, retry, retired-owner fail-stop\n", points);
    return 0;
}
