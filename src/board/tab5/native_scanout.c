/* Native DCS/DPI/VDMA implementation. ESP-IDF v5.4.4 LL definitions and
 * driver sequencing are Apache-2.0; no SDK runtime or allocator is linked.
 * Exclusive DW-GDMA channel 0 ownership, CPU0 CLIC input 18 at the Zig layer. */
#include <stddef.h>
#include <stdint.h>
#include "hal/gpio_ll.h"
#include "hal/mipi_dsi_ll.h"
#include "hal/dw_gdma_ll.h"
#include "soc/ext_mem_defs.h"
#include "hal/clk_gate_ll.h"
#include "soc/interrupts.h"

__asm__(".global DW_GDMA\n.set DW_GDMA,0x50081000\n");
extern int32_t nih_rom_cache_writeback(uint32_t, uint32_t, uint32_t);
extern int32_t nih_rom_cache_invalidate(uint32_t, uint32_t, uint32_t);
typedef struct { uint32_t lane_mbps, dpi_mhz, hbp, hsw, hfp, vbp, vsw, vfp; } nih_dpi_timing;
_Static_assert(sizeof(nih_dpi_timing) == 32, "DPI timing ABI");
_Static_assert(offsetof(hp_sys_clkrst_dev_t, hp_rst_en0) == 0xc0, "boot DMA reset offset");
_Static_assert(offsetof(hp_sys_clkrst_dev_t, soc_clk_ctrl0) == 0x14, "boot DMA CPU clock offset");
_Static_assert(offsetof(hp_sys_clkrst_dev_t, soc_clk_ctrl1) == 0x18, "boot DMA system clock offset");
static dw_gdma_link_list_item_t descriptor;
static uint64_t solid_word __attribute__((aligned(64)));
#ifndef NIH_NATIVE_DISPLAY_SCENE
#define NIH_NATIVE_DISPLAY_SCENE 0
#endif
#if NIH_NATIVE_DISPLAY_TILE
#define TILE_W 128u
#define TILE_H 40u
#define POEM_H 112u
#define SCENE_ROWS (TILE_H + POEM_H + 14u + 10u)
#define SCRATCH_BASE 0x481f2000u
#define SCRATCH_BYTES (TILE_W * POEM_H * 2u)
_Static_assert(SCRATCH_BASE + 2u * SCRATCH_BYTES == 0x48200000u, "private double buffer must end before owner heaps");
static uint16_t title_tile[TILE_H][TILE_W] __attribute__((aligned(64)));
static uint16_t caption_tile[14][TILE_W] __attribute__((aligned(64)));
static uint16_t tagline_tile[10][TILE_W] __attribute__((aligned(64)));
static uint32_t scene_active, scene_pending;
static bool scene_enabled;
#endif
static dw_gdma_link_list_item_t *active_nodes = &descriptor;
static uint32_t node_count = 1;
static bool dma_owned;
static uint32_t completions;
static uint32_t fault;
static uint32_t dsi_error0, dsi_error1, dma_error, bridge_error;
static uint32_t prime_depth;
static uint32_t source_address;
static bool pattern_active;
#define DMA_ERRORS 0x07ffffe0u
#include "keypad_sparse.h"

/* PIN-free touch experiment. Only the fixed SRAM background is changed;
 * descriptors and the logo source remain owned by the existing scanout. */
bool nih_display_touch_feedback(uint32_t color) {
    if (color > UINT16_MAX || !dma_owned || pattern_active ||
        source_address != (uint32_t)(uintptr_t)&solid_word) return false;
    const uint64_t repeated = (uint64_t)color * UINT64_C(0x0001000100010001);
    uint32_t previous_mstatus;
    /* CLIC18 uses the same ROM cache ABI; do not nest cache transactions. */
    __asm__ volatile("csrrc %0,mstatus,%1" : "=r"(previous_mstatus) : "r"(8u) : "memory");
    solid_word = repeated;
    const bool copied = nih_rom_cache_writeback(1u << 4, (uint32_t)(uintptr_t)&solid_word, sizeof(solid_word)) == 0;
    __asm__ volatile("fence iorw,iorw" ::: "memory");
    if (previous_mstatus & 8u) __asm__ volatile("csrsi mstatus,8" ::: "memory");
    return copied;
}

void nih_display_command_setup(void) {
    mipi_dsi_phy_ll_set_switch_time(&MIPI_DSI_HOST, 50, 104, 46, 128);
    mipi_dsi_host_ll_enable_rx_crc(&MIPI_DSI_HOST, true);
    mipi_dsi_host_ll_enable_rx_ecc(&MIPI_DSI_HOST, true);
    mipi_dsi_host_ll_enable_tx_eotp(&MIPI_DSI_HOST, true, false);
    mipi_dsi_host_ll_set_timeout_clock_division(&MIPI_DSI_HOST, 12);
    mipi_dsi_host_ll_set_escape_clock_division(&MIPI_DSI_HOST, 6);
    mipi_dsi_host_ll_set_timeout_count(&MIPI_DSI_HOST, 0, 0, 0, 0, 0, 0, 0);
    mipi_dsi_phy_ll_set_max_read_time(&MIPI_DSI_HOST, 6000);
    mipi_dsi_phy_ll_set_stop_wait_time(&MIPI_DSI_HOST, 0x3f);
    mipi_dsi_host_ll_enable_te_ack(&MIPI_DSI_HOST, false);
    // Write-only bring-up: ACK/BTA responses are not qualified on this panel.
    // Keep both disabled; do not hide any reported PHY/protocol errors.
    mipi_dsi_host_ll_enable_cmd_ack(&MIPI_DSI_HOST, false);
    mipi_dsi_host_ll_enable_bta(&MIPI_DSI_HOST, false);
    mipi_dsi_host_ll_set_dcs_short_wr_speed_mode(&MIPI_DSI_HOST, 0, MIPI_DSI_LL_TRANS_SPEED_LP);
    mipi_dsi_host_ll_set_dcs_short_wr_speed_mode(&MIPI_DSI_HOST, 1, MIPI_DSI_LL_TRANS_SPEED_LP);
    mipi_dsi_host_ll_set_dcs_long_wr_speed_mode(&MIPI_DSI_HOST, MIPI_DSI_LL_TRANS_SPEED_LP);
}
/* Nonblocking FIFO primitives. The Zig caller supplies every deadline. */
uint32_t nih_display_command_status(void) {
    uint32_t result = 0;
    if (!mipi_dsi_host_ll_gen_is_write_fifo_full(&MIPI_DSI_HOST)) result |= 1;
    if (!mipi_dsi_host_ll_gen_is_cmd_fifo_full(&MIPI_DSI_HOST)) result |= 2;
    if (mipi_dsi_host_ll_gen_is_write_fifo_empty(&MIPI_DSI_HOST) &&
        mipi_dsi_host_ll_gen_is_cmd_fifo_empty(&MIPI_DSI_HOST)) result |= 4;
    const uint32_t error0 = MIPI_DSI_HOST.int_st0.val;
    const uint32_t error1 = MIPI_DSI_HOST.int_st1.val;
    dsi_error0 |= error0; dsi_error1 |= error1;
    if (error0 || error1) result |= 8;
    return result;
}
void nih_display_command_payload(uint32_t word) { mipi_dsi_host_ll_gen_write_payload_fifo(&MIPI_DSI_HOST, word); }
void nih_display_command_header(uint32_t type, uint32_t low, uint32_t high) {
    mipi_dsi_host_ll_gen_set_packet_header(&MIPI_DSI_HOST, 0, (mipi_dsi_data_type_t)type, (uint8_t)high, (uint8_t)low);
}

static void dark(void) { gpio_ll_set_level(&GPIO, 22, 0); }
void nih_display_backlight(bool enable) {
    gpio_ll_set_level(&GPIO, 22, enable && dma_owned && completions >= 2 && !fault);
}
uint32_t nih_display_dma_irq_source(void) { return ETS_DW_GDMA_INTR_SOURCE; }
void nih_display_pattern_enable(const nih_dpi_timing *t) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    pattern_active = true;
    mipi_dsi_host_ll_power_on_off(&MIPI_DSI_HOST, false);
    mipi_dsi_brg_ll_enable_dpi_output(&MIPI_DSI_BRIDGE, false);
    mipi_dsi_ll_enable_dpi_clock(0, false);
    const uint32_t clock = t->hsw == 40 ? 60 : 80;
    clk_gate_ll_ref_240m_clk_en(true);
    mipi_dsi_ll_set_dpi_clock_source(0, MIPI_DSI_DPI_CLK_SRC_PLL_F240M);
    mipi_dsi_ll_set_dpi_clock_div(0, 240 / clock);
    mipi_dsi_ll_enable_dpi_clock(0, true);
    const uint32_t denominator = clock * 8;
    mipi_dsi_host_ll_dpi_set_horizontal_timing(&MIPI_DSI_HOST, t->hsw * t->lane_mbps / denominator,
        t->hbp * t->lane_mbps / denominator, 720 * t->lane_mbps / denominator, t->hfp * t->lane_mbps / denominator);
    mipi_dsi_host_ll_dpi_set_pattern_type(&MIPI_DSI_HOST, MIPI_DSI_PATTERN_BAR_VERTICAL);
    mipi_dsi_host_ll_power_on_off(&MIPI_DSI_HOST, true);
    mipi_dsi_host_ll_enable_video_mode(&MIPI_DSI_HOST, true);
    // VPG has its own timing/pixels. Feeding the external DPI path at the
    // same time overflows the host payload FIFO (physical int_st1 bit 7).
    mipi_dsi_brg_ll_update_dpi_config(&MIPI_DSI_BRIDGE);
}
uint32_t nih_display_diagnostic(uint32_t field) {
    switch (field) { case 0: return dsi_error0; case 1: return dsi_error1;
        case 2: return dma_error; case 3: return bridge_error; case 4: return prime_depth;
        case 5: return (GPIO.out.val >> 22) & 1;
        case 6: return (GPIO.enable.val >> 22) & 1;
        case 7: return gpio_ll_get_level(&GPIO, 22);
        case 8: return IO_MUX.gpio[22].val;
        case 9: return GPIO.func_out_sel_cfg[22].val;
        case 10: return source_address;
        case 11: return DW_GDMA.ch[0].sar0.sar0;
        case 12: return descriptor.ctrl_lo.val;
        case 13: return ui_enabled ? (uint32_t)ui_palette[0] : (uint32_t)solid_word;
        case 14: return node_count;
        default: return 0; }
}

bool nih_display_scene_refresh(uint32_t address) {
#if NIH_NATIVE_DISPLAY_TILE && NIH_NATIVE_DISPLAY_SCENE
    if (address != 0x48030000 || (scene_enabled && scene_pending != scene_active)) return false;
    const uint32_t next = scene_enabled ? 1u - scene_active : 0;
    const uint16_t *frame = (const uint16_t *)(uintptr_t)address;
    uint16_t *output = (uint16_t *)(uintptr_t)(SCRATCH_BASE + next * SCRATCH_BYTES);
    for (uint32_t y = 0; y < POEM_H; ++y)
        for (uint32_t x = 0; x < TILE_W; ++x)
            output[y * TILE_W + x] = frame[(452 + y * 376 / POEM_H) * 720 + 164 + x * 404 / TILE_W];
    if (nih_rom_cache_writeback((1u << 4) | (1u << 5), (uint32_t)(uintptr_t)output, SCRATCH_BYTES)) return false;
    scene_pending = next;
    return true;
#else
    (void)address;
    return false;
#endif
}

static bool restart_dma(void) {
    if (ui_enabled) ui_activate();
#if NIH_NATIVE_DISPLAY_TILE && NIH_NATIVE_DISPLAY_SCENE
    if (scene_enabled && scene_active != scene_pending) {
        scene_active = scene_pending;
        for (uint32_t y = 0; y < POEM_H; ++y)
            dw_gdma_ll_lli_set_src_addr(&active_nodes[1 + 2 * TILE_H + 2 * y], SCRATCH_BASE + scene_active * SCRATCH_BYTES + y * TILE_W * 2);
    }
#endif
    for (uint32_t i = 0; i < node_count; ++i)
        dw_gdma_ll_lli_set_block_markers(ui_enabled ? ui_node(i) : &active_nodes[i], false, i + 1 == node_count, true);
    /* UI LLIs are CPU/device shared writeback state. They are accessed only
     * through the non-cached alias after the initial cache handoff. */
    if (!ui_enabled && nih_rom_cache_writeback(1u << 4, (uint32_t)(uintptr_t)active_nodes, node_count * sizeof(*active_nodes))) return false;
    __asm__ volatile("fence iorw,iorw" ::: "memory");
    dw_gdma_ll_channel_set_link_list_master_port(&DW_GDMA, 0, DW_GDMA_LL_MASTER_PORT_MEMORY);
    dw_gdma_ll_channel_set_link_list_head_addr(&DW_GDMA, 0, ui_enabled ? ui_local : (uint32_t)(uintptr_t)active_nodes);
    dw_gdma_ll_channel_enable(&DW_GDMA, 0, true);
    return true;
}

int32_t nih_display_scanout_begin(uint32_t address, const nih_dpi_timing *t, uint32_t sram_solid, uint32_t lease, uint32_t lease_bytes) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    if (dma_owned || address != 0x48030000 || (t->dpi_mhz != 10 && t->dpi_mhz != 20 && t->dpi_mhz != 40 && t->dpi_mhz != 60 && t->dpi_mhz != 80) ||
        (t->lane_mbps != 1000 && t->lane_mbps != 960)) return -1;
    if (sram_solid) {
        solid_word = sram_solid >= 2 ? UINT64_C(0x1082108210821082) : UINT64_MAX;
        if (nih_rom_cache_writeback(1u << 4, (uint32_t)(uintptr_t)&solid_word, sizeof(solid_word))) return -5;
        address = (uint32_t)(uintptr_t)&solid_word;
    }
    source_address = address;
    /* Do not reset or appropriate an already clocked DMA domain. */
    if (dw_gdma_ll_is_bus_clock_enabled(0)) return -2;
    dw_gdma_ll_enable_bus_clock(0, true);
    dma_owned = true;
    dw_gdma_ll_reset_register(0);
    dw_gdma_ll_enable_controller(&DW_GDMA, true);
    dw_gdma_ll_enable_intr_global(&DW_GDMA, true);
    dw_gdma_ll_enable_common_intr_generation(&DW_GDMA, UINT32_MAX, true);
    dw_gdma_ll_enable_common_intr_propagation(&DW_GDMA, UINT32_MAX, false);
    dw_gdma_ll_clear_common_intr(&DW_GDMA, UINT32_MAX);
    dw_gdma_ll_channel_set_trans_flow(&DW_GDMA, 0, DW_GDMA_ROLE_MEM, DW_GDMA_ROLE_PERIPH_DSI, DW_GDMA_FLOW_CTRL_SELF);
    dw_gdma_ll_channel_set_src_multi_block_type(&DW_GDMA, 0, DW_GDMA_BLOCK_TRANSFER_LIST);
    dw_gdma_ll_channel_set_dst_multi_block_type(&DW_GDMA, 0, DW_GDMA_BLOCK_TRANSFER_LIST);
    dw_gdma_ll_channel_set_src_handshake_interface(&DW_GDMA, 0, DW_GDMA_HANDSHAKE_HW);
    dw_gdma_ll_channel_set_dst_handshake_interface(&DW_GDMA, 0, DW_GDMA_HANDSHAKE_HW);
    dw_gdma_ll_channel_set_dst_handshake_periph(&DW_GDMA, 0, DW_GDMA_ROLE_PERIPH_DSI);
    dw_gdma_ll_channel_set_priority(&DW_GDMA, 0, 1);
    dw_gdma_ll_channel_set_src_outstanding_limit(&DW_GDMA, 0, 5);
    dw_gdma_ll_channel_set_dst_outstanding_limit(&DW_GDMA, 0, 2);
    dw_gdma_ll_channel_enable_intr_generation(&DW_GDMA, 0, UINT32_MAX, true);
    dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, 0, UINT32_MAX, false);
    dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, 0, DW_GDMA_LL_CHANNEL_EVENT_DMA_TFR_DONE | DMA_ERRORS, true);
    dw_gdma_ll_channel_clear_intr(&DW_GDMA, 0, UINT32_MAX);
    descriptor = (dw_gdma_link_list_item_t){0};
    dw_gdma_ll_lli_set_src_addr(&descriptor, address);
    dw_gdma_ll_lli_set_dst_addr(&descriptor, MIPI_DSI_BRG_MEM_BASE);
    dw_gdma_ll_lli_set_src_master_port(&descriptor, address);
    dw_gdma_ll_lli_set_dst_master_port(&descriptor, MIPI_DSI_BRG_MEM_BASE);
    dw_gdma_ll_lli_set_src_trans_width(&descriptor, DW_GDMA_TRANS_WIDTH_64);
    dw_gdma_ll_lli_set_dst_trans_width(&descriptor, DW_GDMA_TRANS_WIDTH_64);
    dw_gdma_ll_lli_set_src_burst_mode(&descriptor, sram_solid ? DW_GDMA_BURST_MODE_FIXED : DW_GDMA_BURST_MODE_INCREMENT);
    dw_gdma_ll_lli_set_dst_burst_mode(&descriptor, DW_GDMA_BURST_MODE_FIXED);
    dw_gdma_ll_lli_set_src_burst_items(&descriptor, sram_solid ? DW_GDMA_BURST_ITEMS_1 : DW_GDMA_BURST_ITEMS_512);
    dw_gdma_ll_lli_set_dst_burst_items(&descriptor, DW_GDMA_BURST_ITEMS_256);
    dw_gdma_ll_lli_set_src_burst_len(&descriptor, sram_solid ? 1 : 16);
    dw_gdma_ll_lli_set_dst_burst_len(&descriptor, 16);
    dw_gdma_ll_lli_set_trans_block_size(&descriptor, 720 * 1280 * 2 / 8);
    dw_gdma_ll_lli_set_link_list_master_port(&descriptor, DW_GDMA_LL_MASTER_PORT_MEMORY);
    dw_gdma_ll_lli_set_next_item_addr(&descriptor, 0);
    if (sram_solid == 4) {
        const int32_t result = ui_build(lease, lease_bytes);
        if (result) return result;
    }
#if NIH_NATIVE_DISPLAY_TILE
    if (sram_solid >= 2) {
        const bool scene = NIH_NATIVE_DISPLAY_SCENE && sram_solid == 3;
        const uint32_t rows = scene ? SCENE_ROWS : TILE_H;
        const uint32_t nodes = 1 + 2 * rows;
        if ((lease & 63) || lease < 0x4ff00000 || lease_bytes != nodes * 64 ||
            lease_bytes > 0x4ff28000 - lease || lease >= 0x4ff28000) return -6;
        dw_gdma_link_list_item_t *list = (dw_gdma_link_list_item_t *)(uintptr_t)lease;
        const uint16_t *frame = (const uint16_t *)(uintptr_t)0x48030000;
        for (uint32_t y = 0; y < TILE_H; ++y)
            for (uint32_t x = 0; x < TILE_W; ++x)
                title_tile[y][x] = frame[(170 + y * 87 / TILE_H) * 720 + 86 + x * 284 / TILE_W];
        if (nih_rom_cache_writeback(1u << 4, (uint32_t)(uintptr_t)title_tile, sizeof(title_tile))) return -5;
        if (scene) {
            for (uint32_t y = 0; y < 14; ++y)
                for (uint32_t x = 0; x < TILE_W; ++x)
                    caption_tile[y][x] = frame[(910 + y * 20 / 14) * 720 + 238 + x * 240 / TILE_W];
            for (uint32_t y = 0; y < 10; ++y)
                for (uint32_t x = 0; x < TILE_W; ++x)
                    tagline_tile[y][x] = frame[(1038 + y * 26 / 10) * 720 + 92 + x * 390 / TILE_W];
            if (nih_rom_cache_writeback(1u << 4, (uint32_t)(uintptr_t)caption_tile, sizeof(caption_tile)) ||
                nih_rom_cache_writeback(1u << 4, (uint32_t)(uintptr_t)tagline_tile, sizeof(tagline_tile))) return -5;
        }
        const uint32_t heights[4] = {TILE_H, POEM_H, 14, 10};
        const uint32_t starts[4] = {200, 400, 560, 640};
        const uint32_t sources[4] = {(uint32_t)(uintptr_t)title_tile, SCRATCH_BASE,
            (uint32_t)(uintptr_t)caption_tile, (uint32_t)(uintptr_t)tagline_tile};
        const uint32_t left = (720 - TILE_W) / 2;
        uint32_t index = 0;
        uint32_t total = 720 * starts[0] + left;
        for (uint32_t i = 0; i < nodes; ++i) list[i] = descriptor;
        dw_gdma_ll_lli_set_trans_block_size(&list[index++], total / 4);
        const uint32_t regions = scene ? 4 : 1;
        for (uint32_t region = 0; region < regions; ++region) {
            for (uint32_t y = 0; y < heights[region]; ++y) {
                dw_gdma_ll_lli_set_src_addr(&list[index], sources[region] + y * TILE_W * 2);
                dw_gdma_ll_lli_set_src_burst_mode(&list[index], DW_GDMA_BURST_MODE_INCREMENT);
                if (scene && region == 1) {
                    dw_gdma_ll_lli_set_src_burst_items(&list[index], DW_GDMA_BURST_ITEMS_512);
                    dw_gdma_ll_lli_set_src_burst_len(&list[index], 32);
                }
                dw_gdma_ll_lli_set_trans_block_size(&list[index++], TILE_W / 4);
                total += TILE_W;
                uint32_t gap = 720 - TILE_W;
                if (y + 1 == heights[region]) {
                    if (region + 1 < regions) gap += 720 * (starts[region + 1] - starts[region] - heights[region]);
                    else gap = 720 - left - TILE_W + 720 * (1280 - starts[region] - heights[region]);
                }
                dw_gdma_ll_lli_set_trans_block_size(&list[index++], gap / 4);
                total += gap;
            }
        }
        if (index != nodes || total != 720 * 1280) return -6;
        for (uint32_t i = 0; i < nodes; ++i)
            dw_gdma_ll_lli_set_next_item_addr(&list[i], i + 1 == nodes ? 0 : (uint32_t)(uintptr_t)&list[i + 1]);
        active_nodes = list;
        node_count = nodes;
        scene_enabled = scene;
    }
#else
    (void)lease; (void)lease_bytes;
#endif
    /* First-frame experiments. No global PLL changes. */
    if (t->dpi_mhz > 40) {
        clk_gate_ll_ref_240m_clk_en(true);
        mipi_dsi_ll_set_dpi_clock_source(0, MIPI_DSI_DPI_CLK_SRC_PLL_F240M);
        mipi_dsi_ll_set_dpi_clock_div(0, 240 / t->dpi_mhz);
    } else {
        mipi_dsi_ll_set_dpi_clock_source(0, MIPI_DSI_DPI_CLK_SRC_XTAL);
        mipi_dsi_ll_set_dpi_clock_div(0, 40 / t->dpi_mhz);
    }
    mipi_dsi_host_ll_dpi_set_pattern_type(&MIPI_DSI_HOST, MIPI_DSI_PATTERN_NONE);
    mipi_dsi_ll_enable_dpi_clock(0, true);
    mipi_dsi_host_ll_dpi_set_vcid(&MIPI_DSI_HOST, 0);
    mipi_dsi_host_ll_dpi_set_color_coding(&MIPI_DSI_HOST, LCD_COLOR_FMT_RGB565, 0);
    mipi_dsi_host_ll_dpi_set_timing_polarity(&MIPI_DSI_HOST, false, false, false, false, false);
    mipi_dsi_host_ll_dpi_enable_lp_horizontal_timing(&MIPI_DSI_HOST, true, true);
    mipi_dsi_host_ll_dpi_enable_lp_vertical_timing(&MIPI_DSI_HOST, true, true, true, true);
    mipi_dsi_host_ll_dpi_enable_lp_command(&MIPI_DSI_HOST, true);
    mipi_dsi_host_ll_dpi_enable_frame_ack(&MIPI_DSI_HOST, false);
    mipi_dsi_host_ll_dpi_set_video_burst_type(&MIPI_DSI_HOST, MIPI_DSI_LL_VIDEO_BURST_WITH_SYNC_PULSES);
    mipi_dsi_host_ll_dpi_set_video_packet_pixel_num(&MIPI_DSI_HOST, 720);
    mipi_dsi_host_ll_dpi_set_trunks_num(&MIPI_DSI_HOST, 0);
    mipi_dsi_host_ll_dpi_set_null_packet_size(&MIPI_DSI_HOST, 0);
    const uint32_t denominator = t->dpi_mhz * 8;
    mipi_dsi_host_ll_dpi_set_horizontal_timing(&MIPI_DSI_HOST, t->hsw * t->lane_mbps / denominator,
        t->hbp * t->lane_mbps / denominator, 720 * t->lane_mbps / denominator, t->hfp * t->lane_mbps / denominator);
    mipi_dsi_host_ll_dpi_set_vertical_timing(&MIPI_DSI_HOST, t->vsw, t->vbp, 1280, t->vfp);
    mipi_dsi_brg_ll_set_horizontal_timing(&MIPI_DSI_BRIDGE, t->hsw, t->hbp, 720, t->hfp);
    mipi_dsi_brg_ll_set_vertical_timing(&MIPI_DSI_BRIDGE, t->vsw, t->vbp, 1280, t->vfp);
    mipi_dsi_brg_ll_set_num_pixel_bits(&MIPI_DSI_BRIDGE, 720 * 1280 * 16);
    mipi_dsi_brg_ll_set_underrun_discard_count(&MIPI_DSI_BRIDGE, 720);
    mipi_dsi_brg_ll_set_input_color_format(&MIPI_DSI_BRIDGE, LCD_COLOR_FMT_RGB565);
    mipi_dsi_brg_ll_set_output_color_format(&MIPI_DSI_BRIDGE, LCD_COLOR_FMT_RGB565, 0);
    mipi_dsi_brg_ll_set_flow_controller(&MIPI_DSI_BRIDGE, MIPI_DSI_LL_FLOW_CONTROLLER_DMA);
    mipi_dsi_brg_ll_set_multi_block_number(&MIPI_DSI_BRIDGE, 1);
    mipi_dsi_brg_ll_set_burst_len(&MIPI_DSI_BRIDGE, 256);
    mipi_dsi_brg_ll_set_empty_threshold(&MIPI_DSI_BRIDGE, 768);
    mipi_dsi_brg_ll_clear_interrupt_status(&MIPI_DSI_BRIDGE, UINT32_MAX);
    mipi_dsi_brg_ll_enable_interrupt(&MIPI_DSI_BRIDGE, UINT32_MAX, false);
    mipi_dsi_brg_ll_enable(&MIPI_DSI_BRIDGE, true);
    mipi_dsi_brg_ll_update_dpi_config(&MIPI_DSI_BRIDGE);
    if (!restart_dma()) return -3;
    // Prime the FIFO before video can consume it. Native PSRAM starts much
    // slower than the SDK's calibrated high-speed configuration.
    for (unsigned poll = 0; poll < 100000; ++poll) {
        prime_depth = mipi_dsi_brg_ll_get_fifo_depth(&MIPI_DSI_BRIDGE);
        if (prime_depth >= 768) break;
    }
    if (prime_depth < 768) return -4;
    mipi_dsi_host_ll_enable_video_mode(&MIPI_DSI_HOST, true);
    mipi_dsi_host_ll_set_clock_lane_state(&MIPI_DSI_HOST, MIPI_DSI_LL_CLOCK_LANE_STATE_AUTO);
    mipi_dsi_brg_ll_enable_dpi_output(&MIPI_DSI_BRIDGE, true);
    mipi_dsi_brg_ll_update_dpi_config(&MIPI_DSI_BRIDGE);
    mipi_dsi_brg_ll_enable_interrupt(&MIPI_DSI_BRIDGE, MIPI_DSI_BRG_LL_EVENT_UNDERRUN, true);
    return 0;
}

/* 1 completed frame, 2 DMA/common error, 4 underrun, 8 descriptor handoff error. */
uint32_t nih_display_scanout_poll(void) {
    if (!dma_owned || fault) return 0;
    uint32_t events = dw_gdma_ll_channel_get_intr_status(&DW_GDMA, 0);
    uint32_t common = dw_gdma_ll_get_common_intr_status(&DW_GDMA);
    uint32_t bridge = mipi_dsi_brg_ll_get_interrupt_status(&MIPI_DSI_BRIDGE);
    dw_gdma_ll_channel_clear_intr(&DW_GDMA, 0, events);
    dw_gdma_ll_clear_common_intr(&DW_GDMA, common);
    mipi_dsi_brg_ll_clear_interrupt_status(&MIPI_DSI_BRIDGE, bridge);
    uint32_t result = 0;
    dsi_error0 |= MIPI_DSI_HOST.int_st0.val; dsi_error1 |= MIPI_DSI_HOST.int_st1.val;
    dma_error |= (events & DMA_ERRORS) | common;
    bridge_error |= bridge;
    if (dma_error || dsi_error0 || dsi_error1) result |= 2;
    // The diagnostic VPG generates pixels inside the host, independently of
    // the bridge data FIFO. Retain its status, do not call it DMA qualification.
    if (!pattern_active && (bridge & MIPI_DSI_BRG_LL_EVENT_UNDERRUN)) result |= 4;
    if (!result && (events & DW_GDMA_LL_CHANNEL_EVENT_DMA_TFR_DONE)) {
        if (!restart_dma()) result = 8;
        else { if (completions != UINT32_MAX) ++completions; result = 1; }
    }
    if (result & 14) {
        fault = result;
        dark();
        dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, 0, UINT32_MAX, false);
        dw_gdma_ll_channel_enable(&DW_GDMA, 0, false);
    }
    return result;
}

bool nih_display_scanout_stop(void) {
    dark();
    if (!dma_owned) return true;
    dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, 0, UINT32_MAX, false);
    dw_gdma_ll_channel_enable(&DW_GDMA, 0, false);
    for (unsigned poll = 0; poll < 100000; ++poll) {
        if (!(DW_GDMA.chen0.val & 1)) {
            const int __DECLARE_RCC_ATOMIC_ENV = 0;
            (void)__DECLARE_RCC_ATOMIC_ENV;
            mipi_dsi_brg_ll_enable_interrupt(&MIPI_DSI_BRIDGE, UINT32_MAX, false);
            mipi_dsi_brg_ll_enable_dpi_output(&MIPI_DSI_BRIDGE, false);
            mipi_dsi_brg_ll_enable(&MIPI_DSI_BRIDGE, false);
            mipi_dsi_ll_enable_dpi_clock(0, false);
            dw_gdma_ll_enable_intr_global(&DW_GDMA, false);
            dw_gdma_ll_enable_controller(&DW_GDMA, false);
            dw_gdma_ll_enable_bus_clock(0, false);
            dma_owned = false;
            return true;
        }
    }
    /* Keep this channel/domain and its private memory retired on timeout. */
    return false;
}
