/* SPDX-License-Identifier: Apache-2.0 */
/* Uses the pinned upstream builders and the SDIO startup-event tag order.
 * Capability bits and buffer blocks are representative, not a device capture. */
#include <stdint.h>
#include <stdio.h>
#define CONFIG_ESP_HOSTED_TLV_V2 1
#include "eh_tlv_v2.h"
#include "eh_tlv_tags.h"
#include "eh_common_sdio_cfg.h"

int main(void) {
    uint8_t payload[256] = { 0x22, 0 };
    eh_tlv_builder_t b;
    const struct eh_priv_sdio_buf_config config = { 0, 1, 7, 1, 7 };
    eh_tlv_builder_init(&b, payload + 2, sizeof(payload) - 2);
    if (eh_tlv_pack_v2(&b, 13, 5, 0, 0, 0x03000a, 20, 20, 2) ||
        eh_tlv_add_u8(&b, EH_PRIV_TRANS_SDIO_MODE, 1) ||
        eh_tlv_add_buf(&b, EH_PRIV_SDIO_BUF_CONFIG, &config, sizeof(config)) ||
        eh_tlv_add_u32_le(&b, EH_PRIV_TRANSFER_SIZE, 1536)) return 1;
    payload[1] = (uint8_t)eh_tlv_builder_len(&b);
    return fwrite(payload, 1, payload[1] + 2, stdout) == payload[1] + 2 ? 0 : 1;
}
