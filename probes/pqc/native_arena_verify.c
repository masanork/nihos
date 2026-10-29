/* Experimental public verification fixture and per-call arena, not a service. */
#include "native_arena.h"
#include "mldsa_native.h"
#include "expected_test_vectors_multilevel.h"

void *nih_pqc_arena_alloc(void *ctx, size_t bytes) {
    struct nih_pqc_arena *a = ctx;
    if (!a || !a->bytes || a->used > a->capacity || bytes > a->capacity - a->used ||
        bytes > SIZE_MAX - 31) {
        if (a) a->failures++;
        return NULL;
    }
    size_t rounded = (bytes + 31) & ~(size_t)31;
    if (rounded > a->capacity - a->used) { a->failures++; return NULL; }
    void *result = a->bytes + a->used;
    a->used += rounded;
    if (a->used > a->peak) a->peak = a->used;
    a->allocs++;
    a->live++;
    return result;
}
void nih_pqc_arena_free(void *ctx, void *ptr, size_t bytes) {
    struct nih_pqc_arena *a = ctx;
    (void)bytes;
    if (!a || !ptr || a->live == 0) return;
    a->frees++;
    a->live--;
}

struct nih_pqc_result {
    uint32_t valid, rejected, oom, peak, allocs, frees, failures, live;
    uint32_t verify_ticks, verify_worker0, verify_worker1;
};
extern void nih_pqc_observe(uint32_t out[3]);
static int verify(const uint8_t *message, size_t len, struct nih_pqc_arena *a) {
    return PQCP_MLDSA_NATIVE_MLDSA65_verify(test_vector_sig_65, message, len,
        (const uint8_t *)TEST_VECTOR_CTX, TEST_VECTOR_CTX_LEN, test_vector_pk_65, a);
}
int nih_pqc_arena_fixture(uint8_t *bytes, size_t capacity, struct nih_pqc_result *r) {
    static const uint8_t modified[] = "Xhis is a test message for ML-DSA digital signature algorithm!";
    if (!bytes || !r || ((uintptr_t)bytes & 31) != 0 || capacity < 32) return 1;
    struct nih_pqc_arena a = { .bytes = bytes, .capacity = capacity };
    uint32_t before[3], after[3];
    nih_pqc_observe(before);
    r->valid = verify((const uint8_t *)TEST_VECTOR_MSG, TEST_VECTOR_MSG_LEN, &a) == 0;
    if (a.live != 0 || a.failures != 0) return 2;
    r->peak = (uint32_t)a.peak; r->allocs = a.allocs; r->frees = a.frees;
    a.used = 0;
    r->rejected = verify(modified, sizeof(modified) - 1, &a) == -6;
    nih_pqc_observe(after);
    r->verify_ticks = after[0] - before[0];
    r->verify_worker0 = after[1] - before[1];
    r->verify_worker1 = after[2] - before[2];
    if (a.live != 0 || a.failures != 0) return 3;
    if (a.peak > r->peak) r->peak = (uint32_t)a.peak;
    unsigned prior_allocs = a.allocs;
    a.used = 0; a.capacity = 4096;
    r->oom = verify((const uint8_t *)TEST_VECTOR_MSG, TEST_VECTOR_MSG_LEN, &a) == -2;
    r->allocs = a.allocs; r->frees = a.frees;
    r->failures = a.failures; r->live = a.live;
    return r->valid && r->rejected && r->oom && a.failures > 0 &&
        a.allocs > prior_allocs && a.live == 0 && r->allocs == r->frees ? 0 : 4;
}

/* Experimental bounded copy, not a public request or trust-anchor API. */
enum { PK_LEN = 1952, SIG_LEN = 3309, CTX_MAX = 255, MSG_MAX = 4096,
       SIG_OFF = PK_LEN, CTX_OFF = SIG_OFF + SIG_LEN,
       MSG_OFF = CTX_OFF + CTX_MAX, SNAP_LEN = MSG_OFF + MSG_MAX };
int nih_pqc_snapshot_prepare(uint8_t *snapshot, size_t snapshot_len) {
    if (!snapshot || snapshot_len != SNAP_LEN ||
        TEST_VECTOR_CTX_LEN > CTX_MAX || TEST_VECTOR_MSG_LEN > MSG_MAX) return 1;
    for (size_t i = 0; i < SNAP_LEN; i++) snapshot[i] = 0;
    for (size_t i = 0; i < PK_LEN; i++) snapshot[i] = test_vector_pk_65[i];
    for (size_t i = 0; i < SIG_LEN; i++) snapshot[SIG_OFF+i] = test_vector_sig_65[i];
    for (size_t i = 0; i < TEST_VECTOR_CTX_LEN; i++) snapshot[CTX_OFF+i] = TEST_VECTOR_CTX[i];
    for (size_t i = 0; i < TEST_VECTOR_MSG_LEN; i++) snapshot[MSG_OFF+i] = TEST_VECTOR_MSG[i];
    return 0;
}
static int snapshot_verify(uint8_t *bytes, size_t capacity, uint8_t *snapshot,
    size_t snapshot_len, struct nih_pqc_result *r) {
    if (!bytes || !snapshot || !r || ((uintptr_t)bytes & 31) != 0 ||
        capacity < 32 || snapshot_len != SNAP_LEN) return 1;
    struct nih_pqc_arena a = { .bytes = bytes, .capacity = capacity };
    uint32_t before[3], after[3];
    nih_pqc_observe(before);
    r->valid = PQCP_MLDSA_NATIVE_MLDSA65_verify(snapshot + SIG_OFF, snapshot + MSG_OFF,
        TEST_VECTOR_MSG_LEN, snapshot + CTX_OFF, TEST_VECTOR_CTX_LEN, snapshot, &a) == 0;
    if (a.live || a.failures) return 2;
    r->peak = (uint32_t)a.peak;
    a.used = 0;
    snapshot[MSG_OFF] ^= 1;
    r->rejected = PQCP_MLDSA_NATIVE_MLDSA65_verify(snapshot + SIG_OFF, snapshot + MSG_OFF,
        TEST_VECTOR_MSG_LEN, snapshot + CTX_OFF, TEST_VECTOR_CTX_LEN, snapshot, &a) == -6;
    snapshot[MSG_OFF] ^= 1;
    nih_pqc_observe(after);
    r->verify_ticks = after[0] - before[0];
    r->verify_worker0 = after[1] - before[1];
    r->verify_worker1 = after[2] - before[2];
    if (a.live || a.failures) return 3;
    if (a.peak > r->peak) r->peak = (uint32_t)a.peak;
    unsigned prior = a.allocs;
    a.used = 0; a.capacity = 4096;
    r->oom = PQCP_MLDSA_NATIVE_MLDSA65_verify(snapshot + SIG_OFF, snapshot + MSG_OFF,
        TEST_VECTOR_MSG_LEN, snapshot + CTX_OFF, TEST_VECTOR_CTX_LEN, snapshot, &a) == -2;
    r->allocs = a.allocs; r->frees = a.frees;
    r->failures = a.failures; r->live = a.live;
    return r->valid && r->rejected && r->oom && a.failures > 0 &&
        a.allocs > prior && a.live == 0 && a.allocs == a.frees ? 0 : 4;
}

int nih_pqc_snapshot_fixture(uint8_t *bytes, size_t capacity,
    uint8_t *snapshot, size_t snapshot_len, struct nih_pqc_result *r) {
    if (nih_pqc_snapshot_prepare(snapshot, snapshot_len)) return 1;
    return snapshot_verify(bytes, capacity, snapshot, snapshot_len, r);
}
#if NIHOS_PQC_SNAPSHOT_MUTATION
extern void nih_pqc_snapshot_copied(void);
int nih_pqc_snapshot_mutation_fixture(uint8_t *bytes, size_t capacity,
    uint8_t *snapshot, size_t snapshot_len, const uint8_t *source, struct nih_pqc_result *r) {
    if (!snapshot || !source || snapshot_len != SNAP_LEN) return 1;
    for (size_t i = 0; i < SNAP_LEN; i++) snapshot[i] = source[i];
    nih_pqc_snapshot_copied();
    return snapshot_verify(bytes, capacity, snapshot, snapshot_len, r);
}
#endif
