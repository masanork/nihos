/* SPDX-License-Identifier: Apache-2.0 */
#include "nihos_time_wire.h"
#include <string.h>

static uint64_t read_le(const uint8_t *p, size_t n) {
    uint64_t result = 0;
    for (size_t i = 0; i < n; ++i) result |= (uint64_t)p[i] << (8 * i);
    return result;
}
static void put_le(uint8_t *p, size_t n, uint64_t value) {
    for (size_t i = 0; i < n; ++i) p[i] = (uint8_t)(value >> (8 * i));
}
bool nihos_time_parse(const uint8_t *raw, size_t len, nihos_time_request *req) {
    if (!raw || !req || len != NIHOS_TIME_REQUEST_SIZE || raw[0] != 1 ||
        raw[1] || raw[2] || raw[3]) return false;
    nihos_time_request value = { (uint32_t)read_le(raw + 4, 4), read_le(raw + 8, 8) };
    if (!value.id || !value.generation) return false;
    *req = value;
    return true;
}
void nihos_time_encode(uint8_t out[NIHOS_TIME_RESULT_SIZE], const nihos_time_request *req,
                       bool synced, uint64_t seconds, uint32_t age_seconds) {
    memset(out, 0, NIHOS_TIME_RESULT_SIZE);
    out[0] = 1;
    out[1] = synced ? 1 : 0;
    put_le(out + 4, 4, req->id);
    put_le(out + 8, 8, req->generation);
    if (synced) {
        put_le(out + 16, 8, seconds);
        put_le(out + 24, 4, age_seconds);
    }
}
