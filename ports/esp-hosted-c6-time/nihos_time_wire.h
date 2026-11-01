/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define NIHOS_TIME_REQUEST_ID UINT32_C(0x4e545151)
#define NIHOS_TIME_RESULT_ID UINT32_C(0x4e545152)
#define NIHOS_TIME_REQUEST_SIZE 16
#define NIHOS_TIME_RESULT_SIZE 32

typedef struct { uint32_t id; uint64_t generation; } nihos_time_request;
bool nihos_time_parse(const uint8_t *raw, size_t len, nihos_time_request *req);
void nihos_time_encode(uint8_t out[NIHOS_TIME_RESULT_SIZE], const nihos_time_request *req,
                       bool synced, uint64_t seconds, uint32_t age_seconds);
