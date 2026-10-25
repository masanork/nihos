#include "nihos_probe.h"

#include <inttypes.h>
#include <stdio.h>

enum { INPUT_SIZE = 4096 };

static uint32_t fnv1a(uint32_t hash, uint8_t value) {
    return (hash ^ value) * UINT32_C(16777619);
}

int main(void) {
    uint8_t input[INPUT_SIZE];
    uint32_t expected_checksum = UINT32_C(2166136261);
    uint32_t expected_processed = 0;
    uint32_t expected_rejected = 0;

    for (size_t index = 0; index < INPUT_SIZE; ++index) {
        input[index] = (uint8_t)((index * 17u + 3u) & 0xffu);
        if (input[index] == UINT8_MAX) {
            ++expected_rejected;
        } else {
            expected_checksum = fnv1a(expected_checksum, input[index]);
            ++expected_processed;
        }
    }

    struct nihos_probe_result result = {0};
    const int32_t status = nihos_probe_run(input, INPUT_SIZE, &result);
    if (status != 0 || result.abi_version != NIHOS_PROBE_ABI_VERSION ||
        result.checksum != expected_checksum ||
        result.processed != expected_processed ||
        result.rejected != expected_rejected) {
        fprintf(stderr,
                "probe mismatch: status=%" PRId32 " abi=%" PRIu32
                " checksum=%08" PRIx32 " processed=%" PRIu32
                " rejected=%" PRIu32 "\n",
                status, result.abi_version, result.checksum,
                result.processed, result.rejected);
        return 1;
    }

    printf("ok abi=%" PRIu32 " checksum=%08" PRIx32
           " processed=%" PRIu32 " rejected=%" PRIu32 "\n",
           result.abi_version, result.checksum,
           result.processed, result.rejected);
    return 0;
}
