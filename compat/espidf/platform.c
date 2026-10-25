#include "nihos/platform_abi.h"

#include <stdbool.h>
#include <stddef.h>
#include <string.h>

#include "bsp/display.h"
#include "esp_async_memcpy.h"
#include "esp_attr.h"
#include "esp_chip_info.h"
#include "esp_cache.h"
#include "esp_err.h"
#include "esp_flash.h"
#include "esp_heap_caps.h"
#include "esp_lcd_mipi_dsi.h"
#include "esp_lcd_panel_ops.h"
#include "esp_rom_uart.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "sdkconfig.h"

#define NIH_INTERNAL_ARENA_BYTES (UINT32_C(64) * UINT32_C(1024))
#define NIH_PSRAM_ARENA_BYTES (UINT32_C(1024) * UINT32_C(1024))
#define NIH_DISPLAY_WIDTH UINT32_C(720)
#define NIH_DISPLAY_HEIGHT UINT32_C(1280)
#define NIH_DISPLAY_STRIDE_BYTES (NIH_DISPLAY_WIDTH * UINT32_C(2))
#define NIH_DISPLAY_FRAME_BYTES \
    (NIH_DISPLAY_STRIDE_BYTES * NIH_DISPLAY_HEIGHT)
#define NIH_DISPLAY_DSI_LANE_MBPS UINT32_C(965)
#define NIH_DISPLAY_BRIGHTNESS_PERCENT 35

static void *s_internal_arena;
static void *s_psram_arena;
static async_memcpy_handle_t s_dma;
static SemaphoreHandle_t s_dma_done;
static esp_lcd_panel_handle_t s_display_panel;
static void *s_display_framebuffer;
static SemaphoreHandle_t s_display_refresh_done;
static volatile uint32_t s_display_vsync_count;
static bool s_display_backlight_enabled;

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
    uint32_t flags =
        NIH_MEMORY_WRITABLE | NIH_MEMORY_CACHEABLE | NIH_MEMORY_DMA_DATA;
    switch (kind) {
        case NIH_MEMORY_INTERNAL:
            storage = &s_internal_arena;
            length = NIH_INTERNAL_ARENA_BYTES;
            caps = MALLOC_CAP_INTERNAL | MALLOC_CAP_DMA | MALLOC_CAP_8BIT;
            break;
        case NIH_MEMORY_PSRAM:
            storage = &s_psram_arena;
            length = NIH_PSRAM_ARENA_BYTES;
            caps = MALLOC_CAP_SPIRAM | MALLOC_CAP_DMA | MALLOC_CAP_8BIT;
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

static bool dma_copy_done(async_memcpy_handle_t handle,
                          async_memcpy_event_t *event,
                          void *argument) {
    (void)handle;
    (void)event;
    BaseType_t task_woken = pdFALSE;
    xSemaphoreGiveFromISR((SemaphoreHandle_t)argument, &task_woken);
    return task_woken == pdTRUE;
}

static int32_t ensure_dma(void) {
    if (s_dma != NULL) {
        return NIH_STATUS_OK;
    }

    s_dma_done = xSemaphoreCreateBinary();
    if (s_dma_done == NULL) {
        return NIH_STATUS_NO_MEMORY;
    }

    const async_memcpy_config_t config = {
        .backlog = 1,
        .dma_burst_size = 64,
        .flags = 0,
    };
    if (esp_async_memcpy_install_gdma_axi(&config, &s_dma) != ESP_OK) {
        vSemaphoreDelete(s_dma_done);
        s_dma_done = NULL;
        return NIH_STATUS_IO;
    }
    return NIH_STATUS_OK;
}

int32_t nih_platform_dma_copy(struct nih_dma_copy *copy) {
    if (copy == NULL || copy->source_address == 0 ||
        copy->destination_address == 0 || copy->length == 0 ||
        copy->flags != 0) {
        return NIH_STATUS_INVALID_ARGUMENT;
    }

    int32_t status = ensure_dma();
    if (status != NIH_STATUS_OK) {
        return status;
    }

    int64_t started_us = esp_timer_get_time();
    if (esp_async_memcpy(s_dma,
                         (void *)(uintptr_t)copy->destination_address,
                         (void *)(uintptr_t)copy->source_address, copy->length,
                         dma_copy_done, s_dma_done) != ESP_OK) {
        return NIH_STATUS_IO;
    }
    if (xSemaphoreTake(s_dma_done, pdMS_TO_TICKS(1000)) != pdTRUE) {
        return NIH_STATUS_IO;
    }

    int64_t elapsed_us = esp_timer_get_time() - started_us;
    copy->elapsed_us =
        elapsed_us > UINT32_MAX ? UINT32_MAX : (uint32_t)elapsed_us;
    return NIH_STATUS_OK;
}

static bool IRAM_ATTR display_refresh_done(
    esp_lcd_panel_handle_t panel, esp_lcd_dpi_panel_event_data_t *event,
    void *argument) {
    (void)panel;
    (void)event;
    SemaphoreHandle_t semaphore = (SemaphoreHandle_t)argument;
    ++s_display_vsync_count;
    BaseType_t task_woken = pdFALSE;
    xSemaphoreGiveFromISR(semaphore, &task_woken);
    return task_woken == pdTRUE;
}

static uint32_t elapsed_u32(int64_t started_us) {
    int64_t elapsed_us = esp_timer_get_time() - started_us;
    return elapsed_us > UINT32_MAX ? UINT32_MAX : (uint32_t)elapsed_us;
}

static void fill_display_info(struct nih_display_info *out) {
    *out = (struct nih_display_info){
        .width = NIH_DISPLAY_WIDTH,
        .height = NIH_DISPLAY_HEIGHT,
        .stride_bytes = NIH_DISPLAY_STRIDE_BYTES,
        .pixel_format = NIH_DISPLAY_RGB565_LE,
        .framebuffer_address =
            (uint32_t)(uintptr_t)s_display_framebuffer,
        .framebuffer_bytes = NIH_DISPLAY_FRAME_BYTES,
        .framebuffer_flags = NIH_DISPLAY_FRAME_WRITABLE |
                             NIH_DISPLAY_FRAME_CACHEABLE |
                             NIH_DISPLAY_FRAME_SCANOUT,
    };
}

static int32_t wait_display_refresh(uint32_t timeout_ms,
                                    uint32_t *elapsed_us,
                                    uint32_t *vsync_count) {
    if (s_display_panel == NULL || s_display_refresh_done == NULL) {
        return NIH_STATUS_UNSUPPORTED;
    }

    while (xSemaphoreTake(s_display_refresh_done, 0) == pdTRUE) {
    }
    TickType_t timeout_ticks = pdMS_TO_TICKS(timeout_ms);
    if (timeout_ticks == 0) {
        timeout_ticks = 1;
    }

    int64_t started_us = esp_timer_get_time();
    if (xSemaphoreTake(s_display_refresh_done, timeout_ticks) != pdTRUE) {
        return NIH_STATUS_IO;
    }
    *elapsed_us = elapsed_u32(started_us);
    *vsync_count = s_display_vsync_count;
    return NIH_STATUS_OK;
}

int32_t nih_platform_display_init(struct nih_display_info *out) {
    if (out == NULL) {
        return NIH_STATUS_INVALID_ARGUMENT;
    }
    if (s_display_panel != NULL) {
        fill_display_info(out);
        return NIH_STATUS_OK;
    }

    s_display_refresh_done = xSemaphoreCreateBinary();
    if (s_display_refresh_done == NULL) {
        return NIH_STATUS_NO_MEMORY;
    }

    const bsp_display_config_t config = {
        .dsi_bus = {
            .phy_clk_src = MIPI_DSI_PHY_CLK_SRC_DEFAULT,
            /* 965 Mbps is the official ST7121 setting and remains above the
             * bandwidth required by the other supported Tab5 timings. */
            .lane_bit_rate_mbps = NIH_DISPLAY_DSI_LANE_MBPS,
        },
    };
    esp_lcd_panel_io_handle_t io = NULL;
    if (bsp_display_new(&config, &s_display_panel, &io) != ESP_OK) {
        s_display_panel = NULL;
        vSemaphoreDelete(s_display_refresh_done);
        s_display_refresh_done = NULL;
        return NIH_STATUS_IO;
    }
    (void)io;

    if (esp_lcd_dpi_panel_get_frame_buffer(s_display_panel, 1,
                                           &s_display_framebuffer) != ESP_OK ||
        s_display_framebuffer == NULL) {
        bsp_display_delete();
        s_display_panel = NULL;
        vSemaphoreDelete(s_display_refresh_done);
        s_display_refresh_done = NULL;
        return NIH_STATUS_IO;
    }

    const esp_lcd_dpi_panel_event_callbacks_t callbacks = {
        .on_color_trans_done = NULL,
        .on_refresh_done = display_refresh_done,
    };
    if (esp_lcd_dpi_panel_register_event_callbacks(
            s_display_panel, &callbacks, s_display_refresh_done) != ESP_OK) {
        bsp_display_delete();
        s_display_panel = NULL;
        s_display_framebuffer = NULL;
        vSemaphoreDelete(s_display_refresh_done);
        s_display_refresh_done = NULL;
        return NIH_STATUS_IO;
    }

    memset(s_display_framebuffer, 0, NIH_DISPLAY_FRAME_BYTES);
    if (esp_cache_msync(s_display_framebuffer, NIH_DISPLAY_FRAME_BYTES,
                        ESP_CACHE_MSYNC_FLAG_DIR_C2M) != ESP_OK ||
        esp_lcd_panel_draw_bitmap(s_display_panel, 0, 0, NIH_DISPLAY_WIDTH,
                                  NIH_DISPLAY_HEIGHT,
                                  s_display_framebuffer) != ESP_OK ||
        esp_lcd_panel_disp_on_off(s_display_panel, true) != ESP_OK) {
        bsp_display_delete();
        s_display_panel = NULL;
        s_display_framebuffer = NULL;
        vSemaphoreDelete(s_display_refresh_done);
        s_display_refresh_done = NULL;
        return NIH_STATUS_IO;
    }

    fill_display_info(out);
    return NIH_STATUS_OK;
}

int32_t nih_platform_display_present(struct nih_display_present *present) {
    if (present == NULL || present->flags != 0 ||
        present->framebuffer_address == 0 ||
        present->framebuffer_address !=
            (uint32_t)(uintptr_t)s_display_framebuffer ||
        present->framebuffer_bytes < NIH_DISPLAY_FRAME_BYTES) {
        return NIH_STATUS_INVALID_ARGUMENT;
    }

    int64_t started_us = esp_timer_get_time();
    if (esp_lcd_panel_draw_bitmap(s_display_panel, 0, 0, NIH_DISPLAY_WIDTH,
                                  NIH_DISPLAY_HEIGHT,
                                  s_display_framebuffer) != ESP_OK) {
        return NIH_STATUS_IO;
    }
    uint32_t wait_us = 0;
    int32_t status = wait_display_refresh(1000, &wait_us,
                                          &present->vsync_count);
    if (status != NIH_STATUS_OK) {
        return status;
    }
    (void)wait_us;
    present->elapsed_us = elapsed_u32(started_us);

    if (!s_display_backlight_enabled) {
        if (bsp_display_brightness_set(NIH_DISPLAY_BRIGHTNESS_PERCENT) !=
            ESP_OK) {
            return NIH_STATUS_IO;
        }
        s_display_backlight_enabled = true;
    }
    return NIH_STATUS_OK;
}

int32_t nih_platform_display_wait_vsync(struct nih_display_vsync *vsync) {
    if (vsync == NULL || vsync->timeout_ms == 0 ||
        vsync->timeout_ms > 1000 || vsync->flags != 0) {
        return NIH_STATUS_INVALID_ARGUMENT;
    }
    return wait_display_refresh(vsync->timeout_ms, &vsync->elapsed_us,
                                &vsync->vsync_count);
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
