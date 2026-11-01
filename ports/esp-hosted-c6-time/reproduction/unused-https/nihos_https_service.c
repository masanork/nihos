/* SPDX-License-Identifier: Apache-2.0 */
#include "sdkconfig.h"

#ifdef CONFIG_NIHOS_HTTPS_SERVICE

#include "nihos_https_service.h"
#include "nihos_https_wire.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "esp_crt_bundle.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "esp_netif_sntp.h"
#include "esp_system.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "slave_control.h"

#define RESULT_FLAG_TLS_VERIFIED UINT16_C(1)
#define RESULT_FLAG_TIME_SYNCED  UINT16_C(2)
#define RESULT_FLAG_TRUNCATED    UINT16_C(4)
#define MINIMUM_VALID_TIME       INT64_C(1704067200) /* 2024-01-01 UTC */

static const char *TAG = "nihos_https";
static QueueHandle_t job_queue;
static atomic_bool operation_active;
static atomic_bool clock_synced;

static void put_le16(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)value;
    p[1] = (uint8_t)(value >> 8);
}

static void put_le32(uint8_t *p, uint32_t value)
{
    for (unsigned i = 0; i < 4; ++i) {
        p[i] = (uint8_t)(value >> (8 * i));
    }
}

static void put_le64(uint8_t *p, uint64_t value)
{
    for (unsigned i = 0; i < 8; ++i) {
        p[i] = (uint8_t)(value >> (8 * i));
    }
}

static void send_result(const nihos_https_job_t *job, nihos_https_status_t status,
                        uint16_t flags, int32_t transport_error, int32_t tls_error,
                        uint32_t tls_flags, uint16_t http_status, int32_t content_length,
                        int64_t unix_time, const uint8_t *body, uint16_t body_len)
{
    size_t len = NIHOS_HTTPS_RESULT_HEADER_LEN + body_len;
    uint8_t *result = calloc(1, len);
    if (!result) {
        ESP_LOGE(TAG, "cannot allocate %u-byte result", (unsigned)len);
        return;
    }
    result[0] = NIHOS_HTTPS_VERSION;
    result[1] = 1;
    put_le16(result + 2, flags);
    put_le32(result + 4, job ? job->request_id : 0);
    put_le64(result + 8, job ? job->generation : 0);
    put_le32(result + 16, (uint32_t)status);
    put_le32(result + 20, (uint32_t)transport_error);
    put_le32(result + 24, (uint32_t)tls_error);
    put_le32(result + 28, tls_flags);
    put_le16(result + 32, http_status);
    put_le16(result + 34, body_len);
    put_le32(result + 36, (uint32_t)content_length);
    put_le64(result + 40, (uint64_t)unix_time);
    put_le32(result + 48, esp_get_free_heap_size());
    put_le32(result + 52, esp_get_minimum_free_heap_size());
    if (body_len) {
        memcpy(result + NIHOS_HTTPS_RESULT_HEADER_LEN, body, body_len);
    }
    esp_err_t err = esp_hosted_send_custom_data(NIHOS_HTTPS_RESULT_MESSAGE_ID,
                                                 result, len);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "result delivery failed: %s", esp_err_to_name(err));
    }
    free(result);
}

static void time_sync_callback(struct timeval *tv)
{
    (void)tv;
    atomic_store(&clock_synced, true);
}

static bool synchronize_time(time_t *now)
{
    if (!atomic_load(&clock_synced)) {
        if (esp_netif_sntp_sync_wait(pdMS_TO_TICKS(10000)) != ESP_OK) {
            return false;
        }
        atomic_store(&clock_synced, true);
    }
    time(now);
    return (int64_t)*now >= MINIMUM_VALID_TIME;
}

static void perform_get(const nihos_https_job_t *job)
{
    time_t now = 0;
    if (!synchronize_time(&now)) {
        send_result(job, NIHOS_HTTPS_TIME_UNAVAILABLE, 0, 0, 0, 0, 0, -1, 0,
                    NULL, 0);
        return;
    }

    uint8_t *body = malloc(job->max_body);
    if (!body) {
        send_result(job, NIHOS_HTTPS_NO_MEMORY, RESULT_FLAG_TIME_SYNCED, 0, 0, 0,
                    0, -1, (int64_t)now, NULL, 0);
        return;
    }
    esp_http_client_config_t config = {
        .host = job->hostname,
        .port = 443,
        .path = job->path,
        .method = HTTP_METHOD_GET,
        .timeout_ms = 10000,
        .disable_auto_redirect = true,
        .max_authorization_retries = -1,
        .transport_type = HTTP_TRANSPORT_OVER_SSL,
        .buffer_size = 512,
        .buffer_size_tx = 512,
        .skip_cert_common_name_check = false,
        .common_name = job->hostname,
        .crt_bundle_attach = esp_crt_bundle_attach,
        .user_agent = "nihos-c6/1",
    };
    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (!client) {
        free(body);
        send_result(job, NIHOS_HTTPS_NO_MEMORY, RESULT_FLAG_TIME_SYNCED, 0, 0, 0,
                    0, -1, (int64_t)now, NULL, 0);
        return;
    }

    int32_t transport_error = esp_http_client_open(client, 0);
    int tls_error_native = 0;
    int tls_verify_flags = 0;
    if (transport_error != ESP_OK) {
        (void)esp_http_client_get_and_clear_last_tls_error(client, &tls_error_native,
                                                           &tls_verify_flags);
        int32_t tls_error = (int32_t)tls_error_native;
        nihos_https_status_t status = (tls_error_native || tls_verify_flags) ?
                                      NIHOS_HTTPS_TLS_FAILED : NIHOS_HTTPS_CONNECT_FAILED;
        esp_http_client_cleanup(client);
        free(body);
        send_result(job, status, RESULT_FLAG_TIME_SYNCED, transport_error, tls_error,
                    (uint32_t)tls_verify_flags, 0, -1, (int64_t)now, NULL, 0);
        return;
    }

    uint16_t flags = RESULT_FLAG_TIME_SYNCED | RESULT_FLAG_TLS_VERIFIED;
    int64_t raw_content_length = esp_http_client_fetch_headers(client);
    int http_status_int = esp_http_client_get_status_code(client);
    uint16_t http_status = (http_status_int >= 0 && http_status_int <= UINT16_MAX) ?
                           (uint16_t)http_status_int : 0;
    int32_t content_length = raw_content_length > INT32_MAX ? INT32_MAX :
                             raw_content_length < -1 ? -1 : (int32_t)raw_content_length;
    uint16_t body_len = 0;
    nihos_https_status_t status = raw_content_length < 0 ?
                                  NIHOS_HTTPS_HTTP_FAILED : NIHOS_HTTPS_OK;
    if (status != NIHOS_HTTPS_OK) {
        transport_error = (int32_t)raw_content_length;
    }
    while (status == NIHOS_HTTPS_OK && body_len < job->max_body) {
        int n = esp_http_client_read(client, (char *)body + body_len,
                                     job->max_body - body_len);
        if (n < 0) {
            status = NIHOS_HTTPS_HTTP_FAILED;
            transport_error = esp_http_client_get_errno(client);
            break;
        }
        if (n == 0) {
            break;
        }
        body_len += (uint16_t)n;
    }
    if (status == NIHOS_HTTPS_OK && !esp_http_client_is_complete_data_received(client)) {
        if (body_len == job->max_body) {
            flags |= RESULT_FLAG_TRUNCATED;
        } else {
            status = NIHOS_HTTPS_HTTP_FAILED;
            transport_error = esp_http_client_get_errno(client);
        }
    }
    esp_http_client_close(client);
    esp_http_client_cleanup(client);
    time(&now);
    send_result(job, status, flags, transport_error, 0, 0, http_status,
                content_length, (int64_t)now, body, body_len);
    free(body);
}

static void https_worker(void *unused)
{
    (void)unused;
    nihos_https_job_t job;
    for (;;) {
        if (xQueueReceive(job_queue, &job, portMAX_DELAY) == pdTRUE) {
            perform_get(&job);
            atomic_store(&operation_active, false);
        }
    }
}

static void request_callback(uint32_t msg_id, const uint8_t *data, size_t len,
                             void *unused)
{
    (void)msg_id;
    (void)unused;
    nihos_https_job_t job = {0};
    if (!nihos_https_parse_request(data, len, &job)) {
        send_result(&job, NIHOS_HTTPS_BAD_REQUEST, 0, 0, 0, 0, 0, -1, 0,
                    NULL, 0);
        return;
    }
    bool expected = false;
    if (!atomic_compare_exchange_strong(&operation_active, &expected, true)) {
        send_result(&job, NIHOS_HTTPS_BUSY, 0, 0, 0, 0, 0, -1, 0, NULL, 0);
        return;
    }
    if (xQueueSend(job_queue, &job, 0) != pdTRUE) {
        atomic_store(&operation_active, false);
        send_result(&job, NIHOS_HTTPS_BUSY, 0, 0, 0, 0, 0, -1, 0, NULL, 0);
    }
}

esp_err_t nihos_https_service_init(void)
{
    job_queue = xQueueCreate(1, sizeof(nihos_https_job_t));
    if (!job_queue) {
        return ESP_ERR_NO_MEM;
    }
    esp_sntp_config_t sntp = ESP_NETIF_SNTP_DEFAULT_CONFIG("pool.ntp.org");
    sntp.sync_cb = time_sync_callback;
    esp_err_t err = esp_netif_sntp_init(&sntp);
    if (err != ESP_OK) {
        return err;
    }
    err = esp_hosted_register_custom_callback(NIHOS_HTTPS_REQUEST_MESSAGE_ID,
                                               request_callback, NULL);
    if (err != ESP_OK) {
        return err;
    }
    if (xTaskCreate(https_worker, "nihos_https", 6144, NULL, 5, NULL) != pdPASS) {
        return ESP_ERR_NO_MEM;
    }
    ESP_LOGI(TAG, "bounded HTTPS service ready; verified TLS and synced time required");
    return ESP_OK;
}

#endif /* CONFIG_NIHOS_HTTPS_SERVICE */

