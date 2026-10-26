/* Independent read-only SDMMC reference using the pinned IDF host/protocol.
 * This oracle is an IDF/FreeRTOS app, not evidence of native kernel execution.
 * No filesystem is mounted and no sector write/erase function is called. */
#include <stdio.h>
#include <stdint.h>
#include "driver/gpio.h"
#include "driver/sdmmc_host.h"
#include "sdmmc_cmd.h"
#include "sd_pwr_ctrl_by_on_chip_ldo.h"
#include "hal/ldo_ll.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static uint8_t buffer[512] __attribute__((aligned(64)));
static uint32_t crc32(const uint8_t *p) {
    uint32_t crc = UINT32_MAX;
    for (unsigned i = 0; i < 512; ++i) {
        crc ^= p[i];
        for (unsigned b = 0; b < 8; ++b) crc = (crc >> 1) ^ ((crc & 1) ? 0xedb88320u : 0);
    }
    return ~crc;
}
void app_main(void) {
    puts("NIHOS_SDMMC_IDF_ORACLE_BEGIN read_only=1 width=1 khz=400");
    gpio_config_t pads = {.pin_bit_mask = 0x3full << 39, .mode = GPIO_MODE_INPUT};
    ESP_ERROR_CHECK(gpio_config(&pads));
    ldo_ll_set_owner(3, LDO_LL_UNIT_OWNER_SW);
    PMU.ext_ldo[4].pmu_ext_ldo.xpd = 0;
    vTaskDelay(pdMS_TO_TICKS(250));
    ESP_ERROR_CHECK(gpio_set_direction(42, GPIO_MODE_OUTPUT));
    ESP_ERROR_CHECK(gpio_set_level(42, 1));
    sd_pwr_ctrl_handle_t power = NULL;
    sd_pwr_ctrl_ldo_config_t power_config = {.ldo_chan_id = 4};
    ESP_ERROR_CHECK(sd_pwr_ctrl_new_on_chip_ldo(&power_config, &power));
    sdmmc_host_t host = SDMMC_HOST_DEFAULT();
    host.slot = 0;
    host.flags = SDMMC_HOST_FLAG_1BIT;
    host.max_freq_khz = 400;
    host.pwr_ctrl_handle = power;
    ESP_ERROR_CHECK(sdmmc_host_init());
    sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
    slot.width = 1;
    slot.clk = 43; slot.cmd = 44; slot.d0 = 39;
    ESP_ERROR_CHECK(sdmmc_host_init_slot(0, &slot));
    sdmmc_card_t card;
    ESP_ERROR_CHECK(sdmmc_card_init(&host, &card));
    printf("NIHOS_SDMMC_IDF_ORACLE_CARD sectors=%lu\n", (unsigned long)card.csd.capacity);
    const uint32_t lbas[] = {0, 1, card.csd.capacity / 2, card.csd.capacity - 1};
    for (unsigned pass = 0; pass < 2; ++pass) {
        for (unsigned i = 0; i < 4; ++i) {
            ESP_ERROR_CHECK(sdmmc_read_sectors(&card, buffer, lbas[i], 1));
            printf("NIHOS_SDMMC_IDF_ORACLE_READ pass=%u lba=%08lx crc=%08lx tail=%02x%02x\n",
                   pass, (unsigned long)lbas[i], (unsigned long)crc32(buffer), buffer[510], buffer[511]);
        }
    }
    puts("NIHOS_SDMMC_IDF_ORACLE_PASS reads=8 writes=0");
}
