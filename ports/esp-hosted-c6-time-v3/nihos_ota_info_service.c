/* SPDX-License-Identifier: Apache-2.0 */
/* Read-only, request-driven OTA layout snapshot. No partition write APIs. */
#include "nihos_ota_info_wire.h"
#include "eh_cp_core.h"
#include "eh_cp_feat_peer_data.h"
#include "esp_flash.h"
#include "esp_flash_encrypt.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_secure_boot.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

static QueueHandle_t queue;
static void request_callback(uint32_t id, const uint8_t *data, size_t len, void *ctx) {
    (void)id; (void)ctx;
    uint32_t nonce;
    if (nihos_ota_info_request(data, len, &nonce)) (void)xQueueSend(queue, &nonce, 0);
}
static void worker(void *unused) {
    (void)unused;
    uint32_t nonce;
    for (;;) if (xQueueReceive(queue, &nonce, portMAX_DELAY) == pdTRUE) {
        nihos_ota_info info = { .nonce = nonce };
        const esp_partition_t *running = esp_ota_get_running_partition();
        const esp_partition_t *boot = esp_ota_get_boot_partition();
        const esp_partition_t *next = esp_ota_get_next_update_partition(NULL);
        if (running) {
            info.flags |= 1; info.running_offset = running->address; info.running_size = running->size;
            esp_ota_img_states_t state;
            if (esp_ota_get_state_partition(running, &state) == ESP_OK) {
                info.flags |= 0x20; info.running_state = (uint32_t)state;
            }
        }
        if (boot) { info.flags |= 2; info.boot_offset = boot->address; info.boot_size = boot->size; }
        if (next) { info.flags |= 4; info.next_offset = next->address; info.next_size = next->size; }
        if (esp_secure_boot_enabled()) info.flags |= 8;
        if (esp_flash_encryption_enabled()) info.flags |= 0x10;
        if (esp_flash_get_size(NULL, &info.flash_size) == ESP_OK) info.flags |= 0x40;
        uint8_t result[NIHOS_OTA_INFO_RESULT_SIZE];
        nihos_ota_info_encode(result, &info);
        esp_err_t err = eh_cp_feat_peer_data_send(NIHOS_OTA_INFO_RESULT_ID, result, sizeof(result));
        if (err != ESP_OK) ESP_LOGW("nihos_ota_info", "send failed: %s", esp_err_to_name(err));
    }
}
static esp_err_t init(void) {
    queue = xQueueCreate(1, sizeof(uint32_t));
    if (!queue) return ESP_ERR_NO_MEM;
    esp_err_t err = eh_cp_feat_peer_data_register_callback(NIHOS_OTA_INFO_REQUEST_ID, request_callback, NULL);
    if (err != ESP_OK) { vQueueDelete(queue); queue = NULL; return err; }
    if (xTaskCreate(worker, "nihos_ota_info", 3072, NULL, 5, NULL) != pdPASS) {
        (void)eh_cp_feat_peer_data_register_callback(NIHOS_OTA_INFO_REQUEST_ID, NULL, NULL);
        vQueueDelete(queue); queue = NULL;
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}
EH_CP_FEAT_REGISTER(init, NULL, "nihos_ota_info", tskNO_AFFINITY, 110);
void nihos_ota_info_link_anchor(void) {}
