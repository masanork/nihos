/* SPDX-License-Identifier: Apache-2.0 */
#include "nihos_ota_info_wire.h"
#include <string.h>

static uint32_t get32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void put32(uint8_t *p, uint32_t n) {
    p[0] = n; p[1] = n >> 8; p[2] = n >> 16; p[3] = n >> 24;
}
bool nihos_ota_info_request(const uint8_t *p, size_t len, uint32_t *nonce) {
    if (!p || !nonce || len != NIHOS_OTA_INFO_REQUEST_SIZE || p[0] != 1 || p[1] || p[2] || p[3]) return false;
    *nonce = get32(p + 4);
    return *nonce != 0;
}
void nihos_ota_info_encode(uint8_t out[NIHOS_OTA_INFO_RESULT_SIZE], const nihos_ota_info *v) {
    memset(out, 0, NIHOS_OTA_INFO_RESULT_SIZE);
    out[0] = 1; out[1] = v->flags;
    put32(out + 4, v->nonce); put32(out + 8, v->flash_size);
    put32(out + 12, v->running_offset); put32(out + 16, v->running_size);
    put32(out + 20, v->boot_offset); put32(out + 24, v->boot_size);
    put32(out + 28, v->next_offset); put32(out + 32, v->next_size);
    put32(out + 36, v->running_state);
}
