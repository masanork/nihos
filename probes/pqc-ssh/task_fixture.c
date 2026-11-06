/* Public deterministic data, emulator-only; no production entropy or SSH. */
#include "kem_job.h"
#include "mlkem_arena.h"
#include <stdint.h>
#include <string.h>
extern int PQCP_MLKEM_NATIVE_MLKEM768_enc_derand(uint8_t *, uint8_t *, const uint8_t *, const uint8_t *, void *);
struct pqc_task_result { uint32_t ok, peak, wrong_epoch, repeat, canceled; };
_Static_assert(sizeof(struct nih_kem_job) <= 2432, "job overlaps public key");
int nih_pqc_task_fixture(uint8_t *bytes, struct pqc_task_result *out) {
    uint8_t seed[64], coins[32];
    memset(seed, 0x37, sizeof seed); memset(coins, 0x48, sizeof coins);
    uint8_t *arena = bytes;
    struct nih_kem_job *job = (void *)(bytes + 32768);
    uint8_t *pk = bytes + 35200, *ct = bytes + 36416, *ss = bytes + 37504, *received = bytes + 37536;
    struct nih_mlkem_arena enc = {.bytes = arena, .capacity = 32768};
    nih_kem_init(job);
    if (nih_kem_begin(job, 1, arena, 32768, seed, pk) != 0) return 1;
    if (PQCP_MLKEM_NATIVE_MLKEM768_enc_derand(ct, ss, pk, coins, &enc) != 0 || enc.live || enc.uncleared || enc.allocs != enc.frees) return 2;
    out->wrong_epoch = nih_kem_decaps(job, 2, arena, 32768, ct, received) == NIH_KEM_BAD_STATE;
    if (nih_kem_decaps(job, 1, arena, 32768, ct, received) != 0 || memcmp(ss, received, 32)) return 3;
    out->peak = (uint32_t)job->arena_peak;
    out->repeat = nih_kem_decaps(job, 1, arena, 32768, ct, received) == NIH_KEM_BAD_STATE;
    if (nih_kem_retire(job, 1) != 0 || nih_kem_begin(job, 2, arena, 32768, seed, pk) != 0) return 4;
    out->canceled = nih_kem_cancel(job, 2) == 0 && nih_kem_retire(job, 2) == 0;
    out->ok = out->wrong_epoch && out->repeat && out->canceled;
    return out->ok ? 0 : 5;
}
