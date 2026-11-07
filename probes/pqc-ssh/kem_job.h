#ifndef NIH_PQC_SSH_KEM_JOB_H
#define NIH_PQC_SSH_KEM_JOB_H
#include <stddef.h>
#include <stdint.h>
/* Experimental serialized caller-owned KEM job, not a scheduler or SSH verifier. */
enum nih_kem_status { NIH_KEM_OK = 0, NIH_KEM_BAD_STATE = -1, NIH_KEM_BACKEND = -2, NIH_KEM_BAD_ARGUMENT = -3 };
enum nih_kem_phase { NIH_KEM_IDLE, NIH_KEM_ACTIVE, NIH_KEM_FINISHED, NIH_KEM_FAILED };
struct nih_kem_job {
    uint8_t secret_key[2400];
    uint32_t epoch;
    enum nih_kem_phase phase;
    size_t arena_peak;
};
/* Caller must own disjoint job, arena and I/O buffers and serialize all calls.
 * Arena is at least 32768 bytes, aligned to 64 bytes. Entropy must be fresh
 * and cryptographically secure. These functions do not obtain entropy. */
/* Initialize once before use; reinitialization would discard epoch history. */
void nih_kem_init(struct nih_kem_job *job);
int nih_kem_begin(struct nih_kem_job *job, uint32_t epoch, uint8_t *arena, size_t arena_len, const uint8_t seed[64], uint8_t public_key[1184]);
int nih_kem_decaps(struct nih_kem_job *job, uint32_t epoch, uint8_t *arena, size_t arena_len, const uint8_t ciphertext[1088], uint8_t secret[32]);
int nih_kem_cancel(struct nih_kem_job *job, uint32_t epoch);
int nih_kem_retire(struct nih_kem_job *job, uint32_t epoch);
#endif
