/* Opt-in channel-1 memory-to-memory DMA diagnostic, not a camera frame.
 * Dedicated SRAM buffers or pinned PSRAM destination and lease remain
 * permanently retained until reset.
 * LL register meanings follow ESP-IDF v5.4.4. CPU0 foreground only. */
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include "hal/dw_gdma_ll.h"
extern int32_t nih_rom_cache_writeback(uint32_t, uint32_t, uint32_t);
extern int32_t nih_rom_cache_invalidate(uint32_t, uint32_t, uint32_t);
extern bool nih_camera_dma_domain_mark_started(uint32_t);
extern bool nih_camera_dma_domain_common(uint32_t, uint32_t *);
#define CH 1u
#define ERRORS 0x07ffffe0u
#define DONE DW_GDMA_LL_CHANNEL_EVENT_DMA_TFR_DONE
#define BYTES 64u
#ifndef TEST_DMA_ENABLE
#define TEST_DMA_ENABLE(on) dw_gdma_ll_channel_enable(&DW_GDMA, CH, (on))
#endif
#ifndef TEST_DMA_ENABLED
#define TEST_DMA_ENABLED() ((DW_GDMA.chen0.val & (1u << CH)) != 0)
#endif
#ifndef TEST_DMA_CLEAR
#define TEST_DMA_CLEAR(bits) dw_gdma_ll_channel_clear_intr(&DW_GDMA, CH, (bits))
#endif
#ifndef TEST_DMA_FENCE
#define TEST_DMA_FENCE() __asm__ volatile("fence iorw,iorw" ::: "memory")
#endif
#ifndef TEST_CACHE_LOCK
#define TEST_CACHE_LOCK(previous) __asm__ volatile("csrrci %0,mstatus,8" : "=r"(previous) :: "memory")
#define TEST_CACHE_UNLOCK(previous) do { if ((previous) & 8u) __asm__ volatile("csrsi mstatus,8" ::: "memory"); } while (0)
#endif
static uint8_t source[BYTES] __attribute__((aligned(64)));
static uint8_t sram_destination[BYTES] __attribute__((aligned(64)));
static uint8_t *destination = sram_destination;
static uint32_t token, events;
static bool active, used;
static bool sync_cache(uint32_t address, bool invalidate) {
    uint32_t previous;
    TEST_CACHE_LOCK(previous);
    TEST_DMA_FENCE();
    const int32_t result = invalidate ? nih_rom_cache_invalidate((1u << 4) | (1u << 5), address, BYTES) :
        nih_rom_cache_writeback((1u << 4) | (1u << 5), address, BYTES);
    TEST_DMA_FENCE();
    TEST_CACHE_UNLOCK(previous);
    return result == 0;
}
/* Caller already holds the generation-specific channel lease. Returns false
 * on any partial failure; the caller must retain the lease until reboot. */
static bool begin_to(uint32_t lease, uint8_t *target) {
    if (used || !lease || !nih_camera_dma_domain_mark_started(lease)) return false;
    used = true;
    token = lease;
    destination = target;
    if (!DW_GDMA.cfg0.dmac_en || TEST_DMA_ENABLED()) return false;
    for (unsigned i = 0; i < BYTES; ++i) { source[i] = (uint8_t)(i * 37u + 13u); destination[i] = 0; }
    if (!sync_cache((uint32_t)(uintptr_t)source, false) ||
        !sync_cache((uint32_t)(uintptr_t)destination, false) ||
        !sync_cache((uint32_t)(uintptr_t)destination, true)) return false;
    dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, CH, UINT32_MAX, false);
    dw_gdma_ll_channel_enable_intr_generation(&DW_GDMA, CH, UINT32_MAX, false);
    TEST_DMA_CLEAR(UINT32_MAX);
    dw_gdma_ll_channel_set_trans_flow(&DW_GDMA, CH, DW_GDMA_ROLE_MEM, DW_GDMA_ROLE_MEM, DW_GDMA_FLOW_CTRL_SELF);
    dw_gdma_ll_channel_set_src_multi_block_type(&DW_GDMA, CH, DW_GDMA_BLOCK_TRANSFER_CONTIGUOUS);
    dw_gdma_ll_channel_set_dst_multi_block_type(&DW_GDMA, CH, DW_GDMA_BLOCK_TRANSFER_CONTIGUOUS);
    dw_gdma_ll_channel_set_src_addr(&DW_GDMA, CH, (uint32_t)(uintptr_t)source);
    dw_gdma_ll_channel_set_dst_addr(&DW_GDMA, CH, (uint32_t)(uintptr_t)destination);
    dw_gdma_ll_channel_set_trans_block_size(&DW_GDMA, CH, BYTES / 8);
    dw_gdma_ll_channel_set_src_master_port(&DW_GDMA, CH, (uint32_t)(uintptr_t)source);
    dw_gdma_ll_channel_set_dst_master_port(&DW_GDMA, CH, (uint32_t)(uintptr_t)destination);
    dw_gdma_ll_channel_set_src_trans_width(&DW_GDMA, CH, DW_GDMA_TRANS_WIDTH_64);
    dw_gdma_ll_channel_set_dst_trans_width(&DW_GDMA, CH, DW_GDMA_TRANS_WIDTH_64);
    dw_gdma_ll_channel_set_src_burst_mode(&DW_GDMA, CH, DW_GDMA_BURST_MODE_INCREMENT);
    dw_gdma_ll_channel_set_dst_burst_mode(&DW_GDMA, CH, DW_GDMA_BURST_MODE_INCREMENT);
    dw_gdma_ll_channel_set_src_burst_items(&DW_GDMA, CH, DW_GDMA_BURST_ITEMS_1);
    dw_gdma_ll_channel_set_dst_burst_items(&DW_GDMA, CH, DW_GDMA_BURST_ITEMS_1);
    dw_gdma_ll_channel_set_src_burst_len(&DW_GDMA, CH, 1);
    dw_gdma_ll_channel_set_dst_burst_len(&DW_GDMA, CH, 1);
    dw_gdma_ll_channel_enable_src_periph_status_write_back(&DW_GDMA, CH, false);
    dw_gdma_ll_channel_enable_dst_periph_status_write_back(&DW_GDMA, CH, false);
    dw_gdma_ll_channel_enable_intr_generation(&DW_GDMA, CH, DONE | ERRORS, true);
    TEST_DMA_FENCE();
    active = true; /* must stop even if enable readback is ambiguous */
    TEST_DMA_ENABLE(true);
    TEST_DMA_FENCE();
    return true;
}
bool nih_camera_dma_test_begin(uint32_t lease) {
    return begin_to(lease, sram_destination);
}
/* The CPU0 caller must hold an exclusive pinned allocation spanning at least
 * 64 bytes. This check rejects non-PSRAM and misaligned addresses, but does not
 * itself prove lease ownership or exclusion from display reservations. */
bool nih_camera_dma_psram_test_begin(uint32_t lease, uint32_t target) {
    if ((target & 63u) || target < 0x48030000u || target > 0x4c000000u - BYTES) return false;
    return begin_to(lease, (uint8_t *)(uintptr_t)target);
}
/* 0 pending, 1 copied and stopped, negative failure. On every terminal result
 * the lease/buffers stay held. A failed stop is never retried as a clean one. */
int32_t nih_camera_dma_test_poll(bool timeout) {
    if (!active) return -1;
    uint32_t common = 0;
    bool common_ok = nih_camera_dma_domain_common(token, &common);
    uint32_t status = dw_gdma_ll_channel_get_intr_status(&DW_GDMA, CH) & (DONE | ERRORS);
    TEST_DMA_CLEAR(status);
    events |= status;
    if (!timeout && common_ok && !common && !(events & (DONE | ERRORS))) return 0;
    dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, CH, UINT32_MAX, false);
    TEST_DMA_ENABLE(false);
    TEST_DMA_FENCE();
    bool stopped = false;
    for (unsigned n = 0; n < 100000; ++n) if (!TEST_DMA_ENABLED()) { stopped = true; break; }
    events |= dw_gdma_ll_channel_get_intr_status(&DW_GDMA, CH) & (DONE | ERRORS);
    TEST_DMA_CLEAR(UINT32_MAX);
    dw_gdma_ll_channel_enable_intr_generation(&DW_GDMA, CH, UINT32_MAX, false);
    active = false;
    uint32_t final_common = 0;
    if (!nih_camera_dma_domain_common(token, &final_common) || !common_ok || common || final_common ||
        timeout || !stopped || !(events & DONE) || (events & ERRORS) ||
        dw_gdma_ll_channel_get_fifo_remain(&DW_GDMA, CH)) return -2;
    TEST_DMA_FENCE();
    if (!sync_cache((uint32_t)(uintptr_t)destination, true)) return -3;
    TEST_DMA_FENCE();
    for (unsigned i = 0; i < BYTES; ++i) if (destination[i] != (uint8_t)(i * 37u + 13u)) return -4;
    return 1;
}
