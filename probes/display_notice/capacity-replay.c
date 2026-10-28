/* Exercise the production dry-run while a prior DMA scene remains owned. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define NIH_NATIVE_CARD_READ 1
#define UI_FOREGROUND
#define SOC_NON_CACHEABLE_OFFSET 0
#define DW_GDMA_BURST_MODE_FIXED 0
#define DW_GDMA_BURST_MODE_INCREMENT 1
#define DW_GDMA_BURST_ITEMS_1 1
#define DW_GDMA_BURST_ITEMS_512 512
typedef struct { uint32_t data[16]; } dw_gdma_link_list_item_t;
static dw_gdma_link_list_item_t descriptor, *active_nodes;
static uint32_t node_count, source_address;
static bool dma_owned;
static uint64_t frame[230400];
static uint32_t spans[4][4];
static const void *input(uint32_t address) {
    if (address == 0x481f2000) return spans;
    if (!address) return NULL;
    assert(address >= 0x48030000 && address < 0x481f2000);
    return (const uint8_t *)frame + address - 0x48030000;
}
#define UI_INPUT(address) input(address)
static int nih_rom_cache_writeback(uint32_t mask, uint32_t start, uint32_t bytes) { (void)mask; (void)start; (void)bytes; return 0; }
static int nih_rom_cache_invalidate(uint32_t mask, uint32_t start, uint32_t bytes) { (void)mask; (void)start; (void)bytes; return 0; }
#define SETTER(name) static void name(dw_gdma_link_list_item_t *n, uint32_t v) { (void)n; (void)v; }
SETTER(dw_gdma_ll_lli_set_src_addr)
SETTER(dw_gdma_ll_lli_set_src_master_port)
SETTER(dw_gdma_ll_lli_set_src_burst_mode)
SETTER(dw_gdma_ll_lli_set_src_burst_items)
SETTER(dw_gdma_ll_lli_set_src_burst_len)
SETTER(dw_gdma_ll_lli_set_trans_block_size)
SETTER(dw_gdma_ll_lli_set_next_item_addr)
#include "../../src/board/tab5/keypad_sparse.h"
int main(void) {
    /* Each pixel span is 256 B, at portrait rows in the same dedup group. */
    spans[0][2] = 1000;
    spans[1][0] = spans[2][0] = 3;
    spans[1][1] = 193 * 1440 + 912; spans[2][1] = 194 * 1440 + 912;
    spans[1][2] = spans[2][2] = 32;
    spans[3][2] = 230400 - 1064;
    memset(frame, 0x31, sizeof(frame));
    assert(nih_display_keypad_memory(0x4ff50000, 0x4ff50300, 0x4ff82000, 0x4ff82040));
    nih_ui_config c = {.plan=0x481f2000, .count=4, .capacity=1280, .scratch=0x4ff50000,
                       .stride=64, .pixels=0x48030000, .pixels_bytes=sizeof(frame)};
    dma_owned = true; ui.count = 99; ui_active = 1;
    assert(nih_display_keypad_fits(&c, c.scratch + 128, 256, false));
    assert(!nih_display_keypad_fits(&c, c.scratch + 128, 256, true));
    assert(!nih_display_keypad_memory(0x4ff50000, 0x4ff50200, 0x4ff82000, 0x4ff82040));
    assert(ui.count == 99 && ui_active == 1 && dma_owned);
    dma_owned = false;
    assert(nih_display_keypad_memory(0x4ff50000, 0x4ff50200, 0x4ff82000, 0x4ff82040));
    dma_owned = true;
    assert(!nih_display_keypad_fits(&c, c.scratch + 128, 256, false));
    assert(ui.count == 99 && ui_active == 1 && dma_owned);
    assert(!nih_display_keypad_fits(&c, c.scratch, 256, false));
    puts("Display capacity replay passed: relocated leases, dedup, OOM before retirement, live state retained");
}
