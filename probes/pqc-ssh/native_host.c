/* Host-only bridge for the pinned mlkem-native arena experiment. */
#include "mlkem_arena.h"
#include "kem_job.h"
#include <stdint.h>
#include <string.h>
extern int PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand(uint8_t *, uint8_t *, const uint8_t *, void *);
extern int PQCP_MLKEM_NATIVE_MLKEM768_dec(uint8_t *, const uint8_t *, const uint8_t *, void *);
static uint8_t workspace[32768] __attribute__((aligned(64)));
static size_t last_peak;
static void erase(void *ptr, size_t len) {
    volatile uint8_t *p = ptr;
    while (len--) *p++ = 0;
}
int nih_host_mlkem_keypair(uint8_t *pk, struct nih_kem_job *job, const uint8_t *seed) {
    nih_kem_init(job);
    int result = nih_kem_begin(job, 1, workspace, sizeof workspace, seed, pk);
    last_peak = job->arena_peak;
    return result == NIH_KEM_OK;
}
int nih_host_mlkem_decaps(uint8_t *ss, const uint8_t *ct, struct nih_kem_job *job) {
    int result = nih_kem_decaps(job, 1, workspace, sizeof workspace, ct, ss);
    if (job->arena_peak > last_peak) last_peak = job->arena_peak;
    return result == NIH_KEM_OK;
}
size_t nih_host_mlkem_peak(void) { return last_peak; }
int nih_host_mlkem_allocation_failure(void) {
    uint8_t pk[1184] = {0}, sk[2400] = {0}, seed[64] = {0}, ss[32] = {0}, ct[1088] = {0};
    struct nih_mlkem_arena a = {.bytes = workspace, .capacity = 0};
    int key_rc = PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand(pk, sk, seed, &a);
    int key_clean = a.live == 0 && a.allocs == a.frees && a.uncleared == 0;
    memset(&a, 0, sizeof a);
    a.bytes = workspace;
    int dec_rc = PQCP_MLKEM_NATIVE_MLKEM768_dec(ss, ct, sk, &a);
    int dec_clean = a.live == 0 && a.allocs == a.frees && a.uncleared == 0;
    erase(workspace, sizeof workspace);
    erase(pk, sizeof pk); erase(sk, sizeof sk); erase(ss, sizeof ss);
    return key_rc == -2 && dec_rc == -2 && key_clean && dec_clean;
}
