#ifndef NIHOS_PROBE_H
#define NIHOS_PROBE_H

#include <stddef.h>
#include <stdint.h>

#define NIHOS_PROBE_ABI_VERSION UINT32_C(1)

struct nihos_probe_result {
    uint32_t abi_version;
    uint32_t checksum;
    uint32_t processed;
    uint32_t rejected;
};

int32_t nihos_probe_run(const uint8_t *input,
                        size_t length,
                        struct nihos_probe_result *out);

#endif
