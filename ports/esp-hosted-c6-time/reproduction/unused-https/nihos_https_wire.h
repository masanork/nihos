/* SPDX-License-Identifier: Apache-2.0 */
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define NIHOS_HTTPS_REQUEST_MESSAGE_ID UINT32_C(0x4e485451)
#define NIHOS_HTTPS_RESULT_MESSAGE_ID  UINT32_C(0x4e485452)
#define NIHOS_HTTPS_VERSION 1
#define NIHOS_HTTPS_REQUEST_HEADER_LEN 24
#define NIHOS_HTTPS_RESULT_HEADER_LEN 56
#define NIHOS_HTTPS_MAX_HOSTNAME 253
#define NIHOS_HTTPS_MAX_PATH 512
#define NIHOS_HTTPS_MAX_BODY 1024

typedef enum {
    NIHOS_HTTPS_OK = 0,
    NIHOS_HTTPS_BAD_REQUEST = 1,
    NIHOS_HTTPS_BUSY = 2,
    NIHOS_HTTPS_NO_MEMORY = 3,
    NIHOS_HTTPS_TIME_UNAVAILABLE = 4,
    NIHOS_HTTPS_CONNECT_FAILED = 5,
    NIHOS_HTTPS_TLS_FAILED = 6,
    NIHOS_HTTPS_HTTP_FAILED = 7,
    NIHOS_HTTPS_INTERNAL = 8,
} nihos_https_status_t;

typedef struct {
    uint32_t request_id;
    uint64_t generation;
    uint16_t max_body;
    char hostname[NIHOS_HTTPS_MAX_HOSTNAME + 1];
    char path[NIHOS_HTTPS_MAX_PATH + 1];
} nihos_https_job_t;

bool nihos_https_parse_request(const uint8_t *data, size_t len,
                               nihos_https_job_t *job);

