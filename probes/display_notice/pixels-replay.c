#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#define NIH_NATIVE_CARD_AUTO 1
#define NIH_NATIVE_CARD_SCENE_EXERCISE 1
#define DW_GDMA_BURST_MODE_FIXED 1
#define DW_GDMA_BURST_MODE_INCREMENT 0
#define DW_GDMA_TRANS_WIDTH_64 3
typedef struct {
    struct { uint32_t sar0; } sar_lo;
    struct { uint32_t val; } sar_hi;
    struct { uint32_t block_ts; } block_ts_lo;
    struct { uint32_t sinc, src_tr_width; } ctrl_lo;
} dw_gdma_link_list_item_t;
static bool dma_owned = true, ui_enabled = true, notice_enabled;
static uint32_t fault, node_count = 2;
static dw_gdma_link_list_item_t nodes[2], *active_nodes = nodes;
static dw_gdma_link_list_item_t *ui_node(unsigned i) { return &nodes[i]; }
static uint64_t expected[230400], palette, pixels[20];
static const volatile uint64_t *actual_pointer(uint32_t a) {
    if (a == 0x4ff17000) return &palette;
    assert(a == 0x4ff70000); return pixels;
}
static const uint64_t *frame(uint32_t a) { assert(a == 0x48030000); return expected; }
#define SCENE_ACTUAL(address) actual_pointer(address)
#define SCENE_EXPECTED(address) frame(address)
#define SCENE_FOREGROUND
#include "../../src/board/tab5/scene_pixels.h"
int main(void) {
    palette = UINT64_C(0xf7bdf7bdf7bdf7bd);
    for (unsigned i = 0; i < 230380; ++i) expected[i] = palette;
    for (unsigned i = 0; i < 20; ++i) pixels[i] = expected[230380 + i] = i * 17;
    nodes[0] = (dw_gdma_link_list_item_t){.sar_lo.sar0=0x4ff17000, .block_ts_lo.block_ts=230379, .ctrl_lo={1,3}};
    nodes[1] = (dw_gdma_link_list_item_t){.sar_lo.sar0=0x4ff70000, .block_ts_lo.block_ts=19, .ctrl_lo={0,3}};
    assert(nih_display_scene_mismatches(0x48030000) == 0);
    pixels[19] ^= 1; assert(nih_display_scene_mismatches(0x48030000) == 1); pixels[19] ^= 1;
    palette ^= 1; assert(nih_display_scene_mismatches(0x48030000) == 230380); palette ^= 1;
    ui_enabled = false; notice_enabled = true;
    assert(nih_display_scene_mismatches(0x48030000) == 0);
    nodes[1].sar_lo.sar0 = 0x48030000; assert(nih_display_scene_mismatches(0x48030000) == UINT32_MAX);
    nodes[1].sar_lo.sar0 = 0x4ff70000; nodes[1].block_ts_lo.block_ts = 20;
    assert(nih_display_scene_mismatches(0x48030000) == UINT32_MAX);
    nodes[1].block_ts_lo.block_ts = 19; nodes[1].ctrl_lo.src_tr_width = 2;
    assert(nih_display_scene_mismatches(0x48030000) == UINT32_MAX);
    nodes[1].ctrl_lo.src_tr_width = 3; fault = 1;
    assert(nih_display_scene_mismatches(0x48030000) == UINT32_MAX);
    fault = 0; dma_owned = false;
    assert(nih_display_scene_mismatches(0x48030000) == UINT32_MAX);
    puts("Scene pixel replay passed: fixed/incremental pixels, corruption and descriptor bounds");
}
