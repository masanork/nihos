/* Link-only roots: one client needs both operations. Never execute this stub. */
#include <stdint.h>
extern int PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand(uint8_t *, uint8_t *, const uint8_t *, void *);
extern int PQCP_MLKEM_NATIVE_MLKEM768_dec(uint8_t *, const uint8_t *, const uint8_t *, void *);
int nih_pqc_ssh_roots(uint8_t *pk, uint8_t *sk, uint8_t *secret, const uint8_t *seed, const uint8_t *ct, void *arena) {
    int rc = PQCP_MLKEM_NATIVE_MLKEM768_keypair_derand(pk, sk, seed, arena);
    return rc ? rc : PQCP_MLKEM_NATIVE_MLKEM768_dec(secret, ct, sk, arena);
}
