/* Opt-in native JPEG fixture. Register sequencing follows ESP-IDF v5.4.4
 * jpeg_encode.c / dma2d.c / jpeg_hal.c (Espressif, Apache-2.0).
 * CPU0 foreground only, caller masks RCC/cache operations. Both JPEG and the
 * entire DMA2D domain must be unused at admission. No DW-GDMA/display reset.
 * All payloads/descriptors remain retained until reset, including on failure.
 */
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "hal/jpeg_ll.h"
#include "hal/dma2d_ll.h"
#include "native_jpeg_tables.h"
#if defined(__riscv)
__asm__(".global JPEG\n.set JPEG,0x50086000\n.global DMA2D\n.set DMA2D,0x50088000\n");
#define FG __attribute__((section(".flash.text.devices")))
#else
#define FG
#endif
extern int32_t nih_rom_cache_writeback(uint32_t, uint32_t, uint32_t);
extern int32_t nih_rom_cache_invalidate(uint32_t, uint32_t, uint32_t);
typedef union { dma2d_descriptor_t d; uint8_t bytes[64]; } __attribute__((aligned(64))) desc_line;
static desc_line tx, rx;
static bool owned, running, failed;
static uint32_t output_address, output_capacity;
static uint32_t rx_seen, tx_seen, jpeg_seen;
static void fence(void) { __asm__ volatile("fence iorw,iorw" ::: "memory"); }
FG uint32_t nih_jpeg_status(uint32_t kind) {
    switch (kind) {
    case 0: return rx_seen;
    case 1: return tx_seen;
    case 2: return jpeg_seen;
    case 3: return running;
    case 4: return failed;
    default: return 0;
    }
}
FG int32_t nih_jpeg_begin(uint32_t source, uint32_t destination, uint32_t capacity) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    if (failed || running || source < 0x48200000u || source > 0x4c000000u - 1843200u ||
        destination != source + 1843200u || capacity < 1024u || capacity > 1843200u ||
        (source & 63u) || (destination & 63u) || (capacity & 63u) || (uint64_t)destination + capacity > 0x4c000000u) return -1;
    if (!owned) {
        if (HP_SYS_CLKRST.soc_clk_ctrl1.reg_jpeg_sys_clk_en || dma2d_ll_is_bus_clock_enabled(0)) return -2;
        owned = true;
        jpeg_ll_enable_bus_clock(true);
        jpeg_ll_reset_module_register();
        dma2d_ll_enable_bus_clock(0, true);
        dma2d_ll_reset_register(0);
        dma2d_ll_hw_enable(&DMA2D, true);
    }
    if (!dma2d_ll_rx_is_fsm_idle(&DMA2D, 0) || !dma2d_ll_tx_is_fsm_idle(&DMA2D, 0)) { failed = true; return -3; }
    output_address = destination; output_capacity = capacity;
    rx_seen = 0; tx_seen = 0; jpeg_seen = 0;
    jpeg_ll_soft_rst(&JPEG);
    jpeg_ll_set_codec_mode(&JPEG, JPEG_CODEC_ENCODER);
    jpeg_ll_config_picture_pixel_format(&JPEG, JPEG_ENC_SRC_RGB565);
    jpeg_ll_sample_mode_select(&JPEG, JPEG_SAMPLE_MODE_YUV422);
    jpeg_ll_set_picture_width(&JPEG, 1280);
    jpeg_ll_set_picture_height(&JPEG, 720);
    jpeg_ll_pixel_reverse(&JPEG, false);
    jpeg_ll_add_tail(&JPEG, true);
    jpeg_ll_enable_ff_check(&JPEG, true);
    jpeg_ll_set_qnr_presition(&JPEG, 0);
    jpeg_ll_set_access_qnr_ram_mode(&JPEG, 1);
    jpeg_ll_luminance_qnr_table_id(&JPEG, 0);
    jpeg_ll_chrominance_qnr_table_id(&JPEG, 1);
    jpeg_ll_write_quantization_coefficient_t0(&JPEG, (uint32_t *)(uintptr_t)jpeg_quant_y);
    jpeg_ll_write_quantization_coefficient_t1(&JPEG, (uint32_t *)(uintptr_t)jpeg_quant_c);
    jpeg_ll_write_quantization_coefficient_t2(&JPEG, (uint32_t *)(uintptr_t)jpeg_quant_y);
    jpeg_ll_write_quantization_coefficient_t3(&JPEG, (uint32_t *)(uintptr_t)jpeg_quant_c);
    jpeg_ll_disable_intr_mask(&JPEG, UINT32_MAX);
    jpeg_ll_clear_intr_mask(&JPEG, UINT32_MAX);
    for (unsigned i = 0; i < sizeof(jpeg_header); ++i) ((uint8_t *)(uintptr_t)destination)[i] = jpeg_header[i];
    if (nih_rom_cache_writeback(48u, destination, sizeof(jpeg_header))) { failed = true; return -4; }
    tx = (desc_line){0}; rx = (desc_line){0};
    const uint32_t payload = capacity - sizeof(jpeg_header);
    rx.d.vb_size = payload & 0x3fffu;
    rx.d.va_size = payload >> 14;
    rx.d.pbyte = 1;
    rx.d.owner = 1;
    rx.d.buffer = (void *)(uintptr_t)(destination + sizeof(jpeg_header));
    tx.d.dma2d_en = 1; tx.d.mode = 1; tx.d.vb_size = 8; tx.d.hb_length = 64;
    tx.d.pbyte = DMA2D_DESCRIPTOR_PBYTE_2B0_PER_PIXEL;
    tx.d.va_size = 720; tx.d.ha_length = 1280; tx.d.owner = 1;
    tx.d.buffer = (void *)(uintptr_t)source;
    if (nih_rom_cache_writeback(16u, (uint32_t)(uintptr_t)&tx, 64) ||
        nih_rom_cache_writeback(16u, (uint32_t)(uintptr_t)&rx, 64)) { failed = true; return -5; }
    dma2d_ll_tx_stop(&DMA2D, 0); dma2d_ll_rx_stop(&DMA2D, 0);
    dma2d_ll_tx_enable_interrupt(&DMA2D, 0, UINT32_MAX, false);
    dma2d_ll_rx_enable_interrupt(&DMA2D, 0, UINT32_MAX, false);
    dma2d_ll_tx_clear_interrupt_status(&DMA2D, 0, UINT32_MAX);
    dma2d_ll_rx_clear_interrupt_status(&DMA2D, 0, UINT32_MAX);
    dma2d_ll_tx_connect_to_periph(&DMA2D, 0, DMA2D_TRIG_PERIPH_JPEG_ENCODER, SOC_DMA2D_TRIG_PERIPH_JPEG_TX);
    dma2d_ll_rx_connect_to_periph(&DMA2D, 0, DMA2D_TRIG_PERIPH_JPEG_ENCODER, SOC_DMA2D_TRIG_PERIPH_JPEG_RX);
    dma2d_ll_tx_enable_reorder(&DMA2D, 0, true);
    dma2d_ll_rx_enable_reorder(&DMA2D, 0, false);
    dma2d_ll_tx_enable_dscr_port(&DMA2D, 0, false);
    dma2d_ll_rx_enable_dscr_port(&DMA2D, 0, false);
    dma2d_ll_tx_enable_owner_check(&DMA2D, 0, false);
    dma2d_ll_rx_enable_owner_check(&DMA2D, 0, false);
    dma2d_ll_tx_enable_auto_write_back(&DMA2D, 0, false);
    dma2d_ll_tx_enable_eof_mode(&DMA2D, 0, true);
    dma2d_ll_rx_set_auto_return_owner(&DMA2D, 0, 0);
    dma2d_ll_tx_enable_descriptor_burst(&DMA2D, 0, true);
    dma2d_ll_rx_enable_descriptor_burst(&DMA2D, 0, true);
    dma2d_ll_tx_set_data_burst_length(&DMA2D, 0, DMA2D_DATA_BURST_LENGTH_128);
    dma2d_ll_rx_set_data_burst_length(&DMA2D, 0, DMA2D_DATA_BURST_LENGTH_128);
    dma2d_ll_tx_enable_page_bound_wrap(&DMA2D, 0, true);
    dma2d_ll_rx_enable_page_bound_wrap(&DMA2D, 0, true);
    dma2d_ll_tx_set_macro_block_size(&DMA2D, 0, DMA2D_MACRO_BLOCK_SIZE_8_16);
    dma2d_ll_rx_set_macro_block_size(&DMA2D, 0, DMA2D_MACRO_BLOCK_SIZE_NONE);
    dma2d_ll_tx_configure_color_space_conv(&DMA2D, 0, DMA2D_CSC_TX_NONE);
    dma2d_ll_tx_set_desc_addr(&DMA2D, 0, (uint32_t)(uintptr_t)&tx);
    dma2d_ll_rx_set_desc_addr(&DMA2D, 0, (uint32_t)(uintptr_t)&rx);
    running = true;
    fence();
    dma2d_ll_tx_start(&DMA2D, 0); dma2d_ll_rx_start(&DMA2D, 0);
    jpeg_ll_process_start(&JPEG);
    return 0;
}
/* 0 pending, positive complete JPEG bytes, negative pinned failure. */
FG int32_t nih_jpeg_poll(void) {
    if (!running || failed) return -1;
    rx_seen |= DMA2D.in_channel[0].in_int_raw.val;
    tx_seen |= DMA2D.out_channel[0].out_int_raw.val;
    jpeg_seen |= JPEG.int_raw.val;
    if ((rx_seen & (DMA2D_LL_RX_EVENT_MASK & ~3u)) || (tx_seen & (DMA2D_LL_TX_EVENT_MASK & ~11u)) ||
        (jpeg_seen & JPEG_LL_ENCODER_EVENT_INTR)) { failed = true; return -2; }
    if (!(rx_seen & DMA2D_LL_EVENT_RX_SUC_EOF)) return 0;
    dma2d_ll_tx_stop(&DMA2D, 0); dma2d_ll_rx_stop(&DMA2D, 0);
    fence();
    if (!dma2d_ll_rx_is_fsm_idle(&DMA2D, 0) || !dma2d_ll_tx_is_fsm_idle(&DMA2D, 0) ||
        !dma2d_ll_rx_is_desc_fsm_idle(&DMA2D, 0) || !dma2d_ll_tx_is_desc_fsm_idle(&DMA2D, 0)) return 0;
    if (nih_rom_cache_invalidate(16u, (uint32_t)(uintptr_t)&rx, 64)) { failed = true; return -3; }
    const uint32_t payload = (rx.d.ha_length << 14) | rx.d.hb_length;
    if (rx.d.owner || rx.d.err_eof || !rx.d.suc_eof || payload < 2 || payload > output_capacity - sizeof(jpeg_header)) { failed = true; return -4; }
    const uint32_t rounded = (payload + 63u) & ~63u;
    if (nih_rom_cache_invalidate(48u, output_address + sizeof(jpeg_header), rounded)) { failed = true; return -5; }
    running = false;
    return (int32_t)(payload + sizeof(jpeg_header));
}
FG void nih_jpeg_abort(void) {
    if (!owned) return;
    failed = true;
    dma2d_ll_tx_stop(&DMA2D, 0); dma2d_ll_rx_stop(&DMA2D, 0);
    jpeg_ll_soft_rst(&JPEG);
    fence();
    /* No resource retirement, reset of DMA2D, or reuse after this point. */
}
