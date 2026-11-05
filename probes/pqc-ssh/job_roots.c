/* Link-only roots. No worker, scheduler, or runtime image. */
#include "kem_job.h"
int nih_pqc_ssh_job_roots(struct nih_kem_job *job, uint32_t epoch, uint8_t *arena, size_t len,
                          const uint8_t *seed, uint8_t *pk, const uint8_t *ct, uint8_t *secret) {
    nih_kem_init(job);
    int rc = nih_kem_begin(job, epoch, arena, len, seed, pk);
    if (rc) return rc;
    if (epoch == UINT32_MAX) return nih_kem_cancel(job, epoch);
    rc = nih_kem_decaps(job, epoch, arena, len, ct, secret);
    if (rc) return rc;
    return nih_kem_retire(job, epoch);
}
