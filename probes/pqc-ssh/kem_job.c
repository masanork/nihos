/* Experimental job with caller-owned memory, single serialized owner. */
#include "kem_job.h"
#include "mlkem_arena.h"
#include <stdint.h>
#include <string.h>
extern int PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand(uint8_t *, uint8_t *, const uint8_t *, void *);
extern int PQCP_MLKEM_NATIVE_MLKEM768_dec(uint8_t *, const uint8_t *, const uint8_t *, void *);
#ifdef NIH_KEM_TEST_FAILURE
extern unsigned nih_kem_test_fail_at;
#define NIH_FAILURE_AT nih_kem_test_fail_at
#else
#define NIH_FAILURE_AT 0
#endif
static void erase(void *ptr, size_t len) {
    volatile uint8_t *p = ptr;
    while (len--) *p++ = 0;
}
static int arena_ok(const uint8_t *p, size_t n) {
    return p && n >= 32768 && ((uintptr_t)p & 63u) == 0;
}
static int clean(const struct nih_mlkem_arena *a) {
    return a->live == 0 && a->allocs == a->frees && a->uncleared == 0;
}
void nih_kem_init(struct nih_kem_job *job) {
    if (job) { erase(job, sizeof *job); job->phase = NIH_KEM_IDLE; }
}
int nih_kem_begin(struct nih_kem_job *job, uint32_t epoch, uint8_t *arena, size_t len, const uint8_t seed[64], uint8_t pk[1184]) {
    if (!job || !seed || !pk || !epoch || !arena_ok(arena, len)) return NIH_KEM_BAD_ARGUMENT;
    if (job->phase != NIH_KEM_IDLE || epoch <= job->epoch) return NIH_KEM_BAD_STATE;
    struct nih_mlkem_arena a = {.bytes = arena, .capacity = len, .fail_at = NIH_FAILURE_AT};
    int rc = PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand(pk, job->secret_key, seed, &a);
    job->epoch = epoch;
    job->arena_peak = a.peak;
    erase(arena, len);
    if (rc || !clean(&a)) {
        erase(job->secret_key, sizeof job->secret_key); erase(pk, 1184);
        job->phase = NIH_KEM_FAILED;
        return NIH_KEM_BACKEND;
    }
    job->phase = NIH_KEM_ACTIVE;
    return NIH_KEM_OK;
}
int nih_kem_decaps(struct nih_kem_job *job, uint32_t epoch, uint8_t *arena, size_t len, const uint8_t ct[1088], uint8_t secret[32]) {
    if (!job || !ct || !secret || !arena_ok(arena, len)) return NIH_KEM_BAD_ARGUMENT;
    if (job->phase != NIH_KEM_ACTIVE || epoch != job->epoch) return NIH_KEM_BAD_STATE;
    struct nih_mlkem_arena a = {.bytes = arena, .capacity = len, .fail_at = NIH_FAILURE_AT};
    int rc = PQCP_MLKEM_NATIVE_MLKEM768_dec(secret, ct, job->secret_key, &a);
    if (a.peak > job->arena_peak) job->arena_peak = a.peak;
    erase(arena, len);
    erase(job->secret_key, sizeof job->secret_key);
    if (rc || !clean(&a)) { erase(secret, 32); job->phase = NIH_KEM_FAILED; return NIH_KEM_BACKEND; }
    job->phase = NIH_KEM_FINISHED;
    return NIH_KEM_OK;
}
int nih_kem_cancel(struct nih_kem_job *job, uint32_t epoch) {
    if (!job || job->phase != NIH_KEM_ACTIVE || epoch != job->epoch) return NIH_KEM_BAD_STATE;
    erase(job->secret_key, sizeof job->secret_key);
    job->phase = NIH_KEM_FINISHED;
    return NIH_KEM_OK;
}
int nih_kem_retire(struct nih_kem_job *job, uint32_t epoch) {
    if (!job || epoch != job->epoch || (job->phase != NIH_KEM_FINISHED && job->phase != NIH_KEM_FAILED)) return NIH_KEM_BAD_STATE;
    erase(job->secret_key, sizeof job->secret_key);
    job->phase = NIH_KEM_IDLE;
    return NIH_KEM_OK;
}
