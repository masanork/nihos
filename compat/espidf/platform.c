#include "nihos/platform_abi.h"

#include <stddef.h>

#include "esp_chip_info.h"
#include "esp_cache.h"
#include "esp_err.h"
#include "esp_flash.h"
#include "esp_heap_caps.h"
#include "esp_rom_uart.h"
#include "sdkconfig.h"

#define NIH_INTERNAL_ARENA_BYTES (UINT32_C(64) * UINT32_C(1024))
#define NIH_PSRAM_ARENA_BYTES (UINT32_C(1024) * UINT32_C(1024))

static void *s_internal_arena;
static void *s_psram_arena;

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

int32_t nih_platform_memory_region(uint32_t kind,
                                   struct nih_memory_region *out) {
    if (out == NULL) {
        return NIH_STATUS_INVALID_ARGUMENT;
    }

    void **storage;
    uint32_t length;
    uint32_t caps;
    uint32_t flags = NIH_MEMORY_WRITABLE;
    switch (kind) {
        case NIH_MEMORY_INTERNAL:
            storage = &s_internal_arena;
            length = NIH_INTERNAL_ARENA_BYTES;
            caps = MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT;
            break;
        case NIH_MEMORY_PSRAM:
            storage = &s_psram_arena;
            length = NIH_PSRAM_ARENA_BYTES;
            caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT;
            flags |= NIH_MEMORY_CACHEABLE;
            break;
        default:
            return NIH_STATUS_UNSUPPORTED;
    }

    if (*storage == NULL) {
        *storage = heap_caps_aligned_alloc(CONFIG_CACHE_L2_CACHE_LINE_SIZE,
                                           length, caps);
        if (*storage == NULL) {
            return NIH_STATUS_NO_MEMORY;
        }
    }

    *out = (struct nih_memory_region){
        .kind = kind,
        .flags = flags,
        .address = (uint32_t)(uintptr_t)*storage,
        .length = length,
        .cache_line_bytes = CONFIG_CACHE_L2_CACHE_LINE_SIZE,
    };
    return NIH_STATUS_OK;
}

int32_t nih_platform_cache_sync(const struct nih_dma_range *range) {
    if (range == NULL || range->address == 0 || range->length == 0 ||
        range->flags != 0) {
        return NIH_STATUS_INVALID_ARGUMENT;
    }

    int flags;
    switch (range->direction) {
        case NIH_DMA_TO_DEVICE:
            flags = ESP_CACHE_MSYNC_FLAG_DIR_C2M;
            break;
        case NIH_DMA_FROM_DEVICE:
            flags = ESP_CACHE_MSYNC_FLAG_DIR_M2C;
            break;
        case NIH_DMA_BIDIRECTIONAL:
            flags = ESP_CACHE_MSYNC_FLAG_DIR_C2M |
                    ESP_CACHE_MSYNC_FLAG_INVALIDATE;
            break;
        default:
            return NIH_STATUS_INVALID_ARGUMENT;
    }

    return esp_cache_msync((void *)(uintptr_t)range->address, range->length,
                           flags) == ESP_OK
               ? NIH_STATUS_OK
               : NIH_STATUS_INVALID_ARGUMENT;
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
