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
#ifdef NIHOS_ORACLE_STORAGE
#include "nihos_storage_probe.h"
static sdmmc_card_t *storage_card;
static uint8_t storage_workspace[NIH_RO_WORKSPACE_BYTES] __attribute__((aligned(64)));
int nih_storage_read(uint32_t lba, void *sector) {
    if (!storage_card || lba >= storage_card->csd.capacity) return -1;
    return sdmmc_read_sectors(storage_card, sector, lba, 1) == ESP_OK ? 0 : -1;
}
#endif

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
    printf("NIHOS_SDMMC_IDF_ORACLE_BEGIN read_only=1 width=%u khz=%u\n", NIHOS_ORACLE_WIDTH, NIHOS_ORACLE_KHZ);
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
    host.flags = SDMMC_HOST_FLAG_1BIT | (NIHOS_ORACLE_WIDTH == 4 ? SDMMC_HOST_FLAG_4BIT : 0);
    host.max_freq_khz = NIHOS_ORACLE_KHZ;
    host.pwr_ctrl_handle = power;
    ESP_ERROR_CHECK(sdmmc_host_init());
    sdmmc_slot_config_t slot = SDMMC_SLOT_CONFIG_DEFAULT();
    slot.width = NIHOS_ORACLE_WIDTH;
    slot.clk = 43; slot.cmd = 44; slot.d0 = 39;
    if (NIHOS_ORACLE_WIDTH == 4) { slot.d1 = 40; slot.d2 = 41; slot.d3 = 42; }
    ESP_ERROR_CHECK(sdmmc_host_init_slot(0, &slot));
    sdmmc_card_t card;
    ESP_ERROR_CHECK(sdmmc_card_init(&host, &card));
    printf("NIHOS_SDMMC_IDF_ORACLE_CARD sectors=%lu\n", (unsigned long)card.csd.capacity);
    printf("NIHOS_SDMMC_IDF_ORACLE_CONFIG width=%u khz=%lu\n", 1u << card.log_bus_width, (unsigned long)card.real_freq_khz);
    const uint32_t lbas[] = {0, 1, card.csd.capacity / 2, card.csd.capacity - 1};
    for (unsigned pass = 0; pass < 2; ++pass) {
        for (unsigned i = 0; i < 4; ++i) {
            ESP_ERROR_CHECK(sdmmc_read_sectors(&card, buffer, lbas[i], 1));
            printf("NIHOS_SDMMC_IDF_ORACLE_READ pass=%u lba=%08lx crc=%08lx tail=%02x%02x\n",
                   pass, (unsigned long)lbas[i], (unsigned long)crc32(buffer), buffer[510], buffer[511]);
            if (pass == 0 && i == 0) {
                printf("NIHOS_SDMMC_IDF_ORACLE_HEADER first64=");
                for (unsigned j = 0; j < 64; ++j) printf("%02x", buffer[j]);
                printf("\n");
            }
        }
    }
    if (NIHOS_ORACLE_SAMPLES) {
        uint32_t digest = 0x811c9dc5u;
        for (unsigned i = 0; i < NIHOS_ORACLE_SAMPLES; ++i) {
            uint32_t lba = (uint32_t)((uint64_t)i * (card.csd.capacity - 1u) / (NIHOS_ORACLE_SAMPLES - 1u));
            ESP_ERROR_CHECK(sdmmc_read_sectors(&card, buffer, lba, 1));
            uint32_t crc = crc32(buffer);
            for (unsigned byte = 0; byte < 8; ++byte) {
                uint32_t word = byte < 4 ? lba : crc;
                digest = (digest ^ ((word >> ((byte % 4) * 8)) & 255u)) * 16777619u;
            }
        }
        printf("NIHOS_SDMMC_IDF_ORACLE_SWEEP samples=%u digest=%08lx\n", NIHOS_ORACLE_SAMPLES, (unsigned long)digest);
    }
#ifdef NIHOS_ORACLE_STORAGE
    storage_card = &card;
    nih_storage_report storage;
    nih_storage_api_report api;
    nih_storage_probe(storage_workspace, sizeof(storage_workspace), card.csd.capacity, &storage, &api);
    printf("NIHOS_STORAGE_IDF");
    const char *names[] = {"status", "error_code", "passes", "block_size", "block_count", "entries", "files", "directories", "directory_digest", "file_bytes", "file_crc", "file_name_digest", "reads", "denied_writes"};
    const uint32_t *values = (const uint32_t *)&storage;
    for (unsigned i = 0; i < sizeof(names)/sizeof(names[0]); ++i) printf(" %s=%08lx", names[i], (unsigned long)values[i]);
    printf("\n");
    printf("NIHOS_STORAGE_API_IDF status=%08lx opens=%08lx closes=%08lx cancelled=%08lx rejected=%08lx read_calls=%08lx workspace_bytes=%08lx used_bytes=%08lx cleared=%08lx\n",
        (unsigned long)api.status,(unsigned long)api.opens,(unsigned long)api.closes,(unsigned long)api.cancelled,(unsigned long)api.rejected,
        (unsigned long)api.read_calls,(unsigned long)api.workspace_bytes,(unsigned long)api.used_bytes,(unsigned long)api.cleared);
    storage_card = NULL;
#endif
    printf("NIHOS_SDMMC_IDF_ORACLE_PASS reads=%u writes=0\n", 8u + NIHOS_ORACLE_SAMPLES);
}
