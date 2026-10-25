#include "nihos_probe.h"

enum { RING_CAPACITY = 64 };

static void consume(uint8_t value, struct nihos_probe_result *out) {
    out->checksum = (out->checksum ^ value) * UINT32_C(16777619);
    ++out->processed;
}

int32_t nihos_probe_run(const uint8_t *input,
                        size_t length,
                        struct nihos_probe_result *out) {
    if (out == NULL) {
        return -1;
    }
    if (input == NULL && length != 0) {
        return -2;
    }

    uint8_t ring[RING_CAPACITY];
    size_t head = 0;
    size_t tail = 0;
    size_t count = 0;

    *out = (struct nihos_probe_result){
        .abi_version = NIHOS_PROBE_ABI_VERSION,
        .checksum = UINT32_C(2166136261),
    };

    for (size_t index = 0; index < length; ++index) {
        const uint8_t value = input[index];
        if (value == UINT8_MAX) {
            ++out->rejected;
            continue;
        }
        if (count == RING_CAPACITY) {
            consume(ring[head], out);
            head = (head + 1u) % RING_CAPACITY;
            --count;
        }
        ring[tail] = value;
        tail = (tail + 1u) % RING_CAPACITY;
        ++count;
    }

    while (count != 0) {
        consume(ring[head], out);
        head = (head + 1u) % RING_CAPACITY;
        --count;
    }
    return 0;
}
