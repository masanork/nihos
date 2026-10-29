/* Experimental public test vector only; no production trust or secrets. */
#include <stdint.h>
#include "mldsa_native.h"
#include "expected_test_vectors_multilevel.h"

int nih_pqc_verify_fixture(void) {
    static const uint8_t modified[] = "Xhis is a test message for ML-DSA digital signature algorithm!";
    int good = PQCP_MLDSA_NATIVE_MLDSA65_verify(test_vector_sig_65,
        (const uint8_t *)TEST_VECTOR_MSG, TEST_VECTOR_MSG_LEN,
        (const uint8_t *)TEST_VECTOR_CTX, TEST_VECTOR_CTX_LEN, test_vector_pk_65);
    int bad = PQCP_MLDSA_NATIVE_MLDSA65_verify(test_vector_sig_65,
        modified, sizeof(modified) - 1,
        (const uint8_t *)TEST_VECTOR_CTX, TEST_VECTOR_CTX_LEN, test_vector_pk_65);
    return good == 0 && bad != 0 ? 0 : 1;
}
