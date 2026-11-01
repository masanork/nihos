/* SPDX-License-Identifier: Apache-2.0 */
#include "nihos_https_wire.h"

#include <string.h>

static uint16_t get_le16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t get_le32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t get_le64(const uint8_t *p)
{
    return (uint64_t)get_le32(p) | ((uint64_t)get_le32(p + 4) << 32);
}

static bool valid_hostname(const uint8_t *name, size_t len)
{
    if (len == 0 || len > NIHOS_HTTPS_MAX_HOSTNAME || name[0] == '.' ||
        name[len - 1] == '.') {
        return false;
    }
    size_t label_len = 0;
    bool label_start = true;
    for (size_t i = 0; i < len; ++i) {
        uint8_t c = name[i];
        if (c == '.') {
            if (label_start || label_len > 63 || name[i - 1] == '-') {
                return false;
            }
            label_len = 0;
            label_start = true;
            continue;
        }
        bool alpha = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
        bool digit = c >= '0' && c <= '9';
        if (!(alpha || digit || c == '-') || (label_start && c == '-')) {
            return false;
        }
        label_start = false;
        if (++label_len > 63) {
            return false;
        }
    }
    return !label_start && name[len - 1] != '-';
}

static bool valid_path(const uint8_t *path, size_t len)
{
    if (len == 0 || len > NIHOS_HTTPS_MAX_PATH || path[0] != '/') {
        return false;
    }
    for (size_t i = 0; i < len; ++i) {
        if (path[i] < 0x21 || path[i] > 0x7e) {
            return false;
        }
    }
    return true;
}

bool nihos_https_parse_request(const uint8_t *data, size_t len,
                               nihos_https_job_t *job)
{
    if (!data || !job || len < NIHOS_HTTPS_REQUEST_HEADER_LEN ||
        data[0] != NIHOS_HTTPS_VERSION || data[1] != 1 ||
        get_le16(data + 2) != 0) {
        return false;
    }
    uint32_t request_id = get_le32(data + 4);
    uint64_t generation = get_le64(data + 8);
    uint16_t port = get_le16(data + 16);
    uint16_t max_body = get_le16(data + 18);
    uint16_t host_len = get_le16(data + 20);
    uint16_t path_len = get_le16(data + 22);
    size_t payload_len = (size_t)host_len + (size_t)path_len;
    if (request_id == 0 || generation == 0 || port != 443 || max_body == 0 ||
        max_body > NIHOS_HTTPS_MAX_BODY || payload_len > SIZE_MAX - NIHOS_HTTPS_REQUEST_HEADER_LEN ||
        len != NIHOS_HTTPS_REQUEST_HEADER_LEN + payload_len ||
        !valid_hostname(data + NIHOS_HTTPS_REQUEST_HEADER_LEN, host_len) ||
        !valid_path(data + NIHOS_HTTPS_REQUEST_HEADER_LEN + host_len, path_len)) {
        return false;
    }
    memset(job, 0, sizeof(*job));
    job->request_id = request_id;
    job->generation = generation;
    job->max_body = max_body;
    memcpy(job->hostname, data + NIHOS_HTTPS_REQUEST_HEADER_LEN, host_len);
    memcpy(job->path, data + NIHOS_HTTPS_REQUEST_HEADER_LEN + host_len, path_len);
    return true;
}

