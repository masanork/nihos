/* Host adapter executes production builders, publication, retirement and pixel
 * checks. Register timing/cache effects are explicitly modeled, not hardware. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include "../../src/platform/native/sram_pool.h"
#define NIH_NATIVE_CARD_READ 1
#define NIH_NATIVE_CARD_AUTO 1
#define NIH_NATIVE_CARD_SCENE_EXERCISE 1
#define UI_FOREGROUND
#define NOTICE_FOREGROUND
#define SCENE_FOREGROUND
#define SCANOUT_RETIRE_FENCE() ((void)0)
#define UI_PUBLISH_FENCE() ((void)0)
#define SOC_NON_CACHEABLE_OFFSET 0
#define DW_GDMA_BURST_MODE_FIXED 1
#define DW_GDMA_BURST_MODE_INCREMENT 0
#define DW_GDMA_BURST_ITEMS_1 1
#define DW_GDMA_BURST_ITEMS_512 512
#define DW_GDMA_TRANS_WIDTH_64 3
typedef struct {
    struct { uint32_t sar0; } sar_lo;
    struct { uint32_t val; } sar_hi;
    struct { uint32_t block_ts; } block_ts_lo;
    struct { uint32_t sinc, src_tr_width; } ctrl_lo;
    uint32_t next, spare[10];
} dw_gdma_link_list_item_t;
_Static_assert(sizeof(dw_gdma_link_list_item_t) == 64, "host LLI geometry");
#include "retire_hal.h"
static dw_gdma_link_list_item_t descriptor, *active_nodes;
static uint32_t node_count, source_address;
static uint8_t ram[2][256 * 1024] __attribute__((aligned(64)));
static uint8_t staging[1843200] __attribute__((aligned(64)));
static uint8_t active_expected[1843200] __attribute__((aligned(64))), pixels[1843200] __attribute__((aligned(64)));
static uint8_t segments[1280 * 16] __attribute__((aligned(64))), textures[65536];
static nih_sram_pool pool;
static nih_sram_lease leases[2];
static uint32_t publications, rejections, frames, mismatches, pending, next_notice, mode_fault;
static uint32_t next_local, next_bytes;
static void *mapped(uint32_t address);
static uint32_t address_of(const void *pointer);
#define UI_INPUT(address) mapped(address)
#define UI_OUTPUT(address) mapped(address)
#define UI_NODE_POINTER(address) mapped(address)
#define UI_ADDRESS(pointer) address_of(pointer)
#define NOTICE_POINTER(address) mapped(address)
#define NOTICE_INPUT(address) mapped(address)
static int nih_rom_cache_writeback(uint32_t mask, uint32_t address, uint32_t bytes) {
    (void)mask; (void)address; (void)bytes; return mode_fault == 4 ? -1 : 0;
}
static int nih_rom_cache_invalidate(uint32_t mask, uint32_t address, uint32_t bytes) {
    return nih_rom_cache_writeback(mask, address, bytes);
}
static void dw_gdma_ll_lli_set_src_addr(dw_gdma_link_list_item_t *n, uint32_t v) { n->sar_lo.sar0 = v; }
static void dw_gdma_ll_lli_set_src_burst_mode(dw_gdma_link_list_item_t *n, uint32_t v) { n->ctrl_lo.sinc = v; }
static void dw_gdma_ll_lli_set_trans_block_size(dw_gdma_link_list_item_t *n, uint32_t v) { assert(v); n->block_ts_lo.block_ts = v - 1; }
static void dw_gdma_ll_lli_set_next_item_addr(dw_gdma_link_list_item_t *n, uint32_t v) { n->next = v; }
#define UNUSED_SETTER(name) static void name(dw_gdma_link_list_item_t *n, uint32_t v) { (void)n; (void)v; }
UNUSED_SETTER(dw_gdma_ll_lli_set_src_master_port)
UNUSED_SETTER(dw_gdma_ll_lli_set_src_burst_items)
UNUSED_SETTER(dw_gdma_ll_lli_set_src_burst_len)
#include "../../src/board/tab5/keypad_sparse.h"
static nih_ui_config candidate;
static void *mapped(uint32_t address) {
    if (!address) return NULL;
    if (address >= 0x10000000 && address < 0x10000000 + sizeof(ui_palette)) return (uint8_t *)ui_palette + address - 0x10000000;
    if (address >= 0x48030000 && address < 0x48030000 + sizeof(staging)) return staging + address - 0x48030000;
    if (address >= 0x481f2000 && address < 0x481f2000 + sizeof(segments)) return segments + address - 0x481f2000;
    for (unsigned i = 0; i < 2; ++i)
        if (leases[i].owner && address >= leases[i].start && address - leases[i].start < leases[i].bytes)
            return ram[i] + address - leases[i].start;
    return NULL;
}
static uint32_t address_of(const void *pointer) {
    const uintptr_t p = (uintptr_t)pointer, palette = (uintptr_t)ui_palette;
    assert(p >= palette && p < palette + sizeof(ui_palette));
    return 0x10000000 + (uint32_t)(p - palette);
}
static bool notice_cache_handoff(uint32_t a, uint32_t n) { return !nih_rom_cache_writeback(0,a,n); }
static void notice_publish_fence(void) {}
#include "../../src/board/tab5/notice_sparse.h"
static bool scene_source_allowed(uint32_t a, uint32_t n) {
    if (a >= 0x10000000 && a < 0x10000000 + sizeof(ui_palette)) return n <= 0x10000000 + sizeof(ui_palette) - a;
    for (unsigned i = 0; i < 2; ++i)
        if (leases[i].owner && a >= leases[i].start && a < leases[i].start + leases[i].bytes && n <= leases[i].start + leases[i].bytes - a) return true;
    return false;
}
#define SCENE_ACTUAL(address) ((const volatile uint64_t *)mapped(address))
#define SCENE_EXPECTED(address) ((const uint64_t *)active_expected)
#include "../../src/board/tab5/scene_pixels.h"
static bool restart_dma(void) {
    ++restarts;
    if (notice_enabled) notice_activate();
    if (ui_enabled) ui_activate();
    return true;
}
#include "../../src/board/tab5/scanout_retire.h"
static void replay(void) {
    if (!(GPIO.out.val & (1u << 22))) { memset(pixels, 0, sizeof(pixels)); return; }
    uint32_t at = ui_enabled ? ui_node_address(0) : notice_head(notice_active), words = 0, count = 0;
    uint64_t *out = (uint64_t *)(void *)pixels;
    while (at && count < 1280) {
        if ((at & 63) || !scene_source_allowed(at,64)) { mismatches = UINT32_MAX; return; }
        const dw_gdma_link_list_item_t *n = mapped(at);
        const uint32_t length = n->block_ts_lo.block_ts + 1;
        const bool fixed = n->ctrl_lo.sinc == DW_GDMA_BURST_MODE_FIXED;
        if (!length || length > 230400 - words || n->sar_hi.val || n->ctrl_lo.src_tr_width != 3 ||
            !scene_source_allowed(n->sar_lo.sar0, fixed ? 8 : length * 8)) { mismatches = UINT32_MAX; return; }
        const uint64_t *src = mapped(n->sar_lo.sar0);
        for (uint32_t i = 0; i < length; ++i) out[words++] = src[fixed ? 0 : i];
        at = n->next; ++count;
    }
    if (at || words != 230400 || count != node_count) { mismatches = UINT32_MAX; return; }
    mismatches = 0;
    const uint64_t *wanted = (const uint64_t *)(const void *)active_expected;
    for (uint32_t i = 0; i < 230400; ++i) if (out[i] != wanted[i]) ++mismatches;
    const uint32_t independent = nih_display_scene_mismatches(0x48030000);
    if (independent > mismatches) mismatches = independent;
}
static bool bind_candidate(void) {
    if (!nih_display_keypad_configure(&candidate)) return false;
    if (candidate.stride) memcpy(ram[0], textures, 2 * candidate.stride);
    if (next_notice) {
        if (!notice_build(0,candidate.count)) return false;
        notice_active = notice_pending = 0; notice_enabled = true; ui_enabled = false; notice_activate();
    } else if (ui_build(next_local,next_bytes)) return false;
    memcpy(active_expected,staging,sizeof(active_expected));
    dma_owned = true; DW_GDMA.chen0.val = 1; video_enabled = true; fifo = 4;
    MIPI_DSI_HOST.vid_pkt_status.val = 0; pause_requested = false;
    completions = 2; nih_display_backlight(true); ++publications; pending = 0;
    replay(); return mismatches == 0;
}
int sim_reset(uint32_t low, uint32_t low_bytes, uint32_t high, uint32_t high_bytes) {
    if (dma_owned && !nih_display_scanout_stop()) return -2;
    memset(ram,0,sizeof(ram)); memset(&pool,0,sizeof(pool)); memset(leases,0,sizeof(leases));
    if (!nih_sram_pool_init(&pool,(nih_sram_region[2]){{low,low_bytes},{high,high_bytes}}) ||
        !nih_sram_pool_take(&pool,1,65536,131072,&leases[0]) ||
        !nih_sram_pool_take(&pool,1,8192,192512,&leases[1]) || leases[0].bytes > sizeof(ram[0]) || leases[1].bytes > sizeof(ram[1])) return -1;
    if (!nih_display_keypad_memory(leases[0].start,leases[0].start+leases[0].bytes,leases[1].start,leases[1].start+leases[1].bytes)) return -1;
    descriptor = (dw_gdma_link_list_item_t){0}; descriptor.ctrl_lo.src_tr_width = 3;
    ui_enabled = notice_enabled = dma_owned = pause_requested = stuck = fifo_stuck = lane_stuck = false;
    mode_fault = fault = publications = rejections = frames = mismatches = pending = backlight_offs = 0;
    GPIO.out.val = 0; memset(pixels,0,sizeof(pixels));
    return 0;
}
int sim_present(const nih_ui_config *config, const uint8_t *frame, const void *plan_data,
                const uint8_t *dynamic, uint32_t dynamic_bytes, uint32_t is_notice) {
    if (pending || fault || !config || !config->count || config->count > 1280) return -2;
    candidate = *config; candidate.scratch = leases[0].start;
    next_local = candidate.scratch + 2 * candidate.stride; next_bytes = candidate.count * 64; next_notice = is_notice;
    if (dynamic_bytes != 2 * candidate.stride || dynamic_bytes > sizeof(textures)) return -1;
    memcpy(staging,frame,sizeof(staging)); memcpy(segments,plan_data,candidate.count * 16);
    if (dynamic_bytes) memcpy(textures,dynamic,dynamic_bytes);
    if (!nih_display_keypad_fits(&candidate,next_local,mode_fault == 5 ? next_bytes - 64 : next_bytes,is_notice)) { ++rejections; return -3; }
    if (!dma_owned) { if (!bind_candidate()) { fault = 8; dark(); return -4; } return 0; }
    if (is_notice && notice_enabled && candidate.paper == ui.paper) {
        if (!nih_display_notice_publish(candidate.count)) { ++rejections; return -4; }
        pending = 2;
    } else {
        if (!nih_display_scanout_pause_request()) return -2;
        pending = 1;
    }
    return 1;
}
int sim_eof(void) {
    if (!dma_owned || fault) return -2;
    ++frames;
    if (!complete_dma_frame()) { fault = 8; dark(); replay(); return -4; }
    if (pending == 1) {
        assert(!dma_owned); memset(ram,0,sizeof(ram));
        if (!bind_candidate()) { fault = 8; dark(); replay(); return -4; }
    } else if (pending == 2) { memcpy(active_expected,staging,sizeof(active_expected)); pending=0; ++publications; }
    replay(); return mismatches ? -5 : 0;
}
int sim_update(uint32_t count, const uint8_t *dynamic, uint32_t bytes, const uint8_t *frame) {
    const uint32_t index = nih_display_keypad_buffer();
    if (pending || index > 1 || bytes != 2 * ui.stride) return -2;
    memcpy(mapped(ui.scratch + index * ui.stride), dynamic + index * ui.stride, ui.stride);
    if (nih_rom_cache_writeback(0,0,0) || !nih_display_keypad_publish(index,count)) return -4;
    memcpy(staging,frame,sizeof(staging)); pending = 2; return 1;
}
void sim_fault(uint32_t value) { mode_fault=value; stuck=value==1; fifo_stuck=value==2; lane_stuck=value==3; }
int sim_corrupt(void) {
    if (!dma_owned || !ui_enabled) return -2;
    for (uint32_t i=0;i<node_count;++i) {
        dw_gdma_link_list_item_t *n=ui_node(i);
        if (n->ctrl_lo.sinc==DW_GDMA_BURST_MODE_INCREMENT) { *(uint64_t *)mapped(n->sar_lo.sar0)^=1; replay(); return mismatches ? 0 : -1; }
    }
    return -1;
}
int sim_shutdown(void) {
    if (!nih_display_scanout_stop()) return -2;
    memset(ram,0,sizeof(ram));
    for (unsigned i=0;i<2;++i) if (leases[i].owner) {
        if (!nih_sram_pool_release(&pool,&leases[i])) return -3;
        leases[i]=(nih_sram_lease){0};
    }
    memset(pixels,0,sizeof(pixels)); pending=0; return 0;
}
void sim_pixels(uint8_t *out) { memcpy(out,pixels,sizeof(pixels)); }
void sim_sram(uint8_t *out) { memcpy(out,ram,sizeof(ram)); }
void sim_metrics(uint32_t out[12]) {
    const uint32_t values[12]={frames,publications,rejections,mismatches,pending,dma_owned,
        GPIO.out.val ? 1u : 0u,backlight_offs,fault,node_count,leases[0].bytes,leases[1].bytes};
    memcpy(out,values,sizeof(values));
}
