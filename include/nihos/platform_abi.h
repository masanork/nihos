#ifndef NIHOS_PLATFORM_ABI_H
#define NIHOS_PLATFORM_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NIH_PLATFORM_ABI_VERSION UINT32_C(1)

enum {
    NIH_STATUS_OK = 0,
    NIH_STATUS_INVALID_ARGUMENT = -1,
    NIH_STATUS_UNSUPPORTED = -2,
    NIH_STATUS_BUSY = -3,
    NIH_STATUS_IO = -4,
    NIH_STATUS_NO_MEMORY = -5,
};

struct nih_boot_info {
    uint32_t abi_version;
    uint32_t chip_revision;
    uint32_t cpu_count;
    uint32_t internal_heap_bytes;
    uint32_t psram_heap_bytes;
    uint32_t flash_bytes;
};

enum nih_dma_direction {
    NIH_DMA_TO_DEVICE = 1,
    NIH_DMA_FROM_DEVICE = 2,
    NIH_DMA_BIDIRECTIONAL = 3,
};

struct nih_dma_range {
    uint32_t address;
    uint32_t length;
    uint32_t direction;
    uint32_t flags;
};

enum nih_memory_kind {
    NIH_MEMORY_INTERNAL = 1,
    NIH_MEMORY_PSRAM = 2,
};

enum {
    NIH_MEMORY_WRITABLE = UINT32_C(1) << 0,
    NIH_MEMORY_CACHEABLE = UINT32_C(1) << 1,
};

struct nih_memory_region {
    uint32_t kind;
    uint32_t flags;
    uint32_t address;
    uint32_t length;
    uint32_t cache_line_bytes;
};

typedef void (*nih_cpu_entry_fn)(void *argument);

int32_t nih_platform_boot_info(struct nih_boot_info *out);
int32_t nih_platform_console_write(const uint8_t *data, uint32_t length);
/* Transfers a bootstrap region to the caller for the firmware lifetime. */
int32_t nih_platform_memory_region(uint32_t kind,
                                   struct nih_memory_region *out);
/* Applies the direction-specific cache ownership transition to the range. */
int32_t nih_platform_cache_sync(const struct nih_dma_range *range);
int32_t nih_platform_cpu_start(uint32_t cpu_id,
                               nih_cpu_entry_fn entry,
                               void *argument);
int32_t nih_platform_flash_guard_enter(void);
void nih_platform_flash_guard_leave(void);

#ifdef __cplusplus
}
#endif

#endif
