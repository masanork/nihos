#include "nihos/platform_abi.h"

#include <stddef.h>

#include "esp_chip_info.h"
#include "esp_err.h"
#include "esp_flash.h"
#include "esp_heap_caps.h"
#include "esp_rom_uart.h"

extern void nihos_zig_main(const struct nih_boot_info *info);

int32_t nih_platform_boot_info(struct nih_boot_info *out) {
    if (out == NULL) {
        return NIH_STATUS_INVALID_ARGUMENT;
    }

    esp_chip_info_t chip;
    uint32_t flash_bytes = 0;
    esp_chip_info(&chip);
    if (esp_flash_get_size(NULL, &flash_bytes) != ESP_OK) {
        return NIH_STATUS_IO;
    }

    *out = (struct nih_boot_info){
        .abi_version = NIH_PLATFORM_ABI_VERSION,
        .chip_revision = chip.revision,
        .cpu_count = chip.cores,
        .internal_heap_bytes =
            (uint32_t)heap_caps_get_total_size(MALLOC_CAP_INTERNAL |
                                               MALLOC_CAP_8BIT),
        .psram_heap_bytes =
            (uint32_t)heap_caps_get_total_size(MALLOC_CAP_SPIRAM),
        .flash_bytes = flash_bytes,
    };
    return NIH_STATUS_OK;
}

int32_t nih_platform_console_write(const uint8_t *data, uint32_t length) {
    if (data == NULL && length != 0) {
        return NIH_STATUS_INVALID_ARGUMENT;
    }
    for (uint32_t index = 0; index < length; ++index) {
        esp_rom_output_tx_one_char(data[index]);
    }
    return NIH_STATUS_OK;
}

void app_main(void) {
    struct nih_boot_info info;
    if (nih_platform_boot_info(&info) != NIH_STATUS_OK) {
        static const uint8_t error[] = "nihos: boot info failed\r\n";
        (void)nih_platform_console_write(error, sizeof(error) - 1u);
        return;
    }
    nihos_zig_main(&info);
}
