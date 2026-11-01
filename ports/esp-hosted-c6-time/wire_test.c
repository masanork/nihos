/* SPDX-License-Identifier: Apache-2.0 */
#include "nihos_time_wire.h"
#include <assert.h>
#include <string.h>
int main(void) {
    uint8_t req[16] = {1,0,0,0, 0x78,0x56,0x34,0x12, 8,7,6,5,4,3,2,1};
    nihos_time_request parsed;
    assert(nihos_time_parse(req, sizeof(req), &parsed));
    assert(parsed.id == UINT32_C(0x12345678) && parsed.generation == UINT64_C(0x0102030405060708));
    assert(!nihos_time_parse(req, 15, &parsed));
    req[2] = 1; assert(!nihos_time_parse(req, sizeof(req), &parsed)); req[2] = 0;
    uint8_t result[32];
    nihos_time_encode(result, &parsed, true, UINT64_C(0x1122334455667788), 42);
    const uint8_t golden[32] = {1,1,0,0,0x78,0x56,0x34,0x12,8,7,6,5,4,3,2,1,
                                0x88,0x77,0x66,0x55,0x44,0x33,0x22,0x11,42,0,0,0,0,0,0,0};
    assert(memcmp(result, golden, sizeof(result)) == 0);
    nihos_time_encode(result, &parsed, false, 999, 44);
    assert(result[1] == 0); for (int i = 16; i < 32; ++i) assert(result[i] == 0);
}
