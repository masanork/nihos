#ifndef NIHOS_PLATFORM_ABI_H
#define NIHOS_PLATFORM_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define NIH_PLATFORM_ABI_VERSION UINT32_C(2)

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
    NIH_MEMORY_DMA_DATA = UINT32_C(1) << 2,
};

struct nih_memory_region {
    uint32_t kind;
    uint32_t flags;
    uint32_t address;
    uint32_t length;
    uint32_t cache_line_bytes;
};

struct nih_dma_copy {
    uint32_t source_address;
    uint32_t destination_address;
    uint32_t length;
    uint32_t flags;
    uint32_t elapsed_us;
};

enum nih_display_pixel_format {
    NIH_DISPLAY_RGB565_LE = 1,
};

enum {
    NIH_DISPLAY_FRAME_WRITABLE = UINT32_C(1) << 0,
    NIH_DISPLAY_FRAME_CACHEABLE = UINT32_C(1) << 1,
    NIH_DISPLAY_FRAME_SCANOUT = UINT32_C(1) << 2,
};

struct nih_display_info {
    uint32_t width;
    uint32_t height;
    uint32_t stride_bytes;
    uint32_t pixel_format;
    uint32_t framebuffer_address;
    uint32_t framebuffer_bytes;
    uint32_t framebuffer_flags;
};

struct nih_display_present {
    uint32_t framebuffer_address;
    uint32_t framebuffer_bytes;
    uint32_t flags;
    uint32_t elapsed_us;
    uint32_t vsync_count;
};

struct nih_display_vsync {
    uint32_t timeout_ms;
    uint32_t flags;
    uint32_t elapsed_us;
    uint32_t vsync_count;
};

typedef void (*nih_cpu_entry_fn)(void *argument);

int32_t nih_platform_boot_info(struct nih_boot_info *out);
int32_t nih_platform_console_write(const uint8_t *data, uint32_t length);
/* Transfers a bootstrap region to the caller for the firmware lifetime. */
int32_t nih_platform_memory_region(uint32_t kind,
                                   struct nih_memory_region *out);
/* Applies the direction-specific cache ownership transition to the range. */
int32_t nih_platform_cache_sync(const struct nih_dma_range *range);
/* Performs one synchronous memory-to-memory DMA transaction. */
int32_t nih_platform_dma_copy(struct nih_dma_copy *copy);
/* Initializes scanout with its backlight off and lends its framebuffer. */
int32_t nih_platform_display_init(struct nih_display_info *out);
/* Makes direct framebuffer writes visible, then waits for the next refresh. */
int32_t nih_platform_display_present(struct nih_display_present *present);
/* Waits for one physical refresh without modifying the framebuffer. */
int32_t nih_platform_display_wait_vsync(struct nih_display_vsync *vsync);
int32_t nih_platform_cpu_start(uint32_t cpu_id,
                               nih_cpu_entry_fn entry,
                               void *argument);
int32_t nih_platform_flash_guard_enter(void);
void nih_platform_flash_guard_leave(void);

#ifdef __cplusplus
}
#endif

#endif
