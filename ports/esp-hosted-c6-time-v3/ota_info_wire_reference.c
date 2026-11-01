/* SPDX-License-Identifier: Apache-2.0 */
#include "nihos_ota_info_wire.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    const uint8_t request[] = { 1, 0, 0, 0, 0x78, 0x56, 0x34, 0x12 };
    const uint8_t invalid[] = { 1, 1, 0, 0, 0x78, 0x56, 0x34, 0x12 };
    const uint8_t zero_nonce[] = { 1, 0, 0, 0, 0, 0, 0, 0 };
    uint32_t nonce = 0;
    assert(nihos_ota_info_request(request, sizeof(request), &nonce));
    assert(nonce == 0x12345678u);
    assert(!nihos_ota_info_request(invalid, sizeof(invalid), &nonce));
    assert(!nihos_ota_info_request(request, sizeof(request) - 1, &nonce));
    assert(!nihos_ota_info_request(zero_nonce, sizeof(zero_nonce), &nonce));
    assert(!nihos_ota_info_request(NULL, sizeof(request), &nonce));
    assert(!nihos_ota_info_request(request, sizeof(request), NULL));
    const nihos_ota_info info = { .nonce = 0x12345678u, .flags = 0x67,
        .flash_size = 0x400000, .running_offset = 0x10000, .running_size = 0x180000,
        .boot_offset = 0x10000, .boot_size = 0x180000,
        .next_offset = 0x190000, .next_size = 0x180000, .running_state = 2 };
    uint8_t bytes[NIHOS_OTA_INFO_RESULT_SIZE];
    nihos_ota_info_encode(bytes, &info);
    return fwrite(bytes, 1, sizeof(bytes), stdout) == sizeof(bytes) ? 0 : 1;
}
