/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define NIHOS_OTA_INFO_REQUEST_ID 0x4e4f4951u
#define NIHOS_OTA_INFO_RESULT_ID  0x4e4f4952u
#define NIHOS_OTA_INFO_REQUEST_SIZE 8u
#define NIHOS_OTA_INFO_RESULT_SIZE 40u

typedef struct {
    uint32_t nonce, flash_size;
    uint32_t running_offset, running_size, boot_offset, boot_size;
    uint32_t next_offset, next_size, running_state;
    uint8_t flags;
} nihos_ota_info;

bool nihos_ota_info_request(const uint8_t *bytes, size_t len, uint32_t *nonce);
void nihos_ota_info_encode(uint8_t out[NIHOS_OTA_INFO_RESULT_SIZE], const nihos_ota_info *info);
