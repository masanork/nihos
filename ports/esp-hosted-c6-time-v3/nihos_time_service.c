/* SPDX-License-Identifier: Apache-2.0 */
#include "nihos_time_service.h"
#include "nihos_time_wire.h"
#include <limits.h>
#include <sys/time.h>
#include "eh_cp_feat_peer_data.h"
#include "eh_cp_core.h"
#include "esp_log.h"
#include "esp_netif_sntp.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

static QueueHandle_t queue;
static portMUX_TYPE sync_lock = portMUX_INITIALIZER_UNLOCKED;
static int64_t last_sync_us = -1;

static void synced(struct timeval *tv) {
    (void)tv;
    int64_t now = esp_timer_get_time();
    portENTER_CRITICAL(&sync_lock);
    last_sync_us = now;
    portEXIT_CRITICAL(&sync_lock);
}
static void request_callback(uint32_t msg_id, const uint8_t *raw, size_t len, void *ctx) {
    (void)msg_id; (void)ctx;
    nihos_time_request request;
    if (nihos_time_parse(raw, len, &request)) {
        /* Never block Hosted's RX thread. Queue saturation produces a timeout. */
        (void)xQueueSend(queue, &request, 0);
    }
}
static void worker(void *unused) {
    (void)unused;
    nihos_time_request request;
    for (;;) if (xQueueReceive(queue, &request, portMAX_DELAY) == pdTRUE) {
        int64_t last;
        portENTER_CRITICAL(&sync_lock);
        last = last_sync_us;
        portEXIT_CRITICAL(&sync_lock);
        int64_t now = esp_timer_get_time();
        struct timeval wall;
        bool known = last >= 0 && now >= last && gettimeofday(&wall, NULL) == 0 && wall.tv_sec >= 0;
        uint64_t elapsed = known ? (uint64_t)(now - last) / 1000000 : 0;
        uint32_t age = elapsed > UINT32_MAX ? UINT32_MAX : (uint32_t)elapsed;
        uint8_t result[NIHOS_TIME_RESULT_SIZE];
        nihos_time_encode(result, &request, known, known ? (uint64_t)wall.tv_sec : 0, age);
        esp_err_t err = eh_cp_feat_peer_data_send(NIHOS_TIME_RESULT_ID, result, sizeof(result));
        if (err != ESP_OK) ESP_LOGW("nihos_time", "result enqueue failed: %s", esp_err_to_name(err));
    }
}
esp_err_t nihos_time_service_init(void) {
    queue = xQueueCreate(1, sizeof(nihos_time_request));
    if (!queue) return ESP_ERR_NO_MEM;
    if (xTaskCreate(worker, "nihos_time", 3072, NULL, 5, NULL) != pdPASS) return ESP_ERR_NO_MEM;
    esp_err_t err = eh_cp_feat_peer_data_register_callback(NIHOS_TIME_REQUEST_ID, request_callback, NULL);
    if (err != ESP_OK) return err;
    esp_sntp_config_t config = ESP_NETIF_SNTP_DEFAULT_CONFIG("pool.ntp.org");
    config.sync_cb = synced;
    return esp_netif_sntp_init(&config);
}

/* Core initializes registered features in ascending priority, with peer_data
 * at 90. The host is notified only after this initialization task completes. */
EH_CP_FEAT_REGISTER(nihos_time_service_init, NULL, "nihos_time", tskNO_AFFINITY, 100);

/* Referenced by app_main so the linker extracts this object from main.a. */
void nihos_time_service_link_anchor(void) {}
