/* Run the production bank builder/publication code with in-memory DMA LLIs.
 * No hardware, panel, card, credential or identity values are involved. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#define NIH_NATIVE_CARD_AUTO 1
#define NOTICE_FOREGROUND
#define DW_GDMA_BURST_MODE_FIXED 0
#define DW_GDMA_BURST_MODE_INCREMENT 1
#define DW_GDMA_BURST_ITEMS_1 1
#define DW_GDMA_BURST_ITEMS_512 512
typedef struct { uint32_t source, words, next, mode, items, length, spare[10]; } dw_gdma_link_list_item_t;
typedef struct { uint32_t kind, offset, words, reserved; } nih_ui_span;
static struct { uint32_t plan, pixels, pixels_bytes, capacity, label_height, paper; } ui;
static bool ui_runtime = true, dma_owned;
static uint32_t fault, node_count, source_address;
static dw_gdma_link_list_item_t descriptor, *active_nodes;
static uint8_t banks[2][94 * 1024] __attribute__((aligned(64)));
static uint8_t frame[1843200] __attribute__((aligned(64)));
static nih_ui_span plan[1280];
static bool cache_ok = true;
static unsigned handoffs;
static void *bank_pointer(uint32_t address) {
    assert(address >= 0x4ff70000 && address < 0x4ff9f000);
    return (uint8_t *)banks + address - 0x4ff70000;
}
static const void *input_pointer(uint32_t address) {
    if (address == 0x481f2000) return plan;
    assert(address >= 0x48030000 && address < 0x48030000 + sizeof(frame));
    return frame + address - 0x48030000;
}
#define NOTICE_POINTER(address) bank_pointer(address)
#define NOTICE_INPUT(address) input_pointer(address)
static bool notice_cache_handoff(uint32_t address, uint32_t bytes) {
    assert(bytes == sizeof(banks[0]));
    assert(address == 0x4ff70000 || address == 0x4ff70000 + sizeof(banks[0]));
    ++handoffs; return cache_ok;
}
static void notice_publish_fence(void) {}
#define SETTER(name, field) static void name(dw_gdma_link_list_item_t *n, uint32_t v) { n->field = v; }
SETTER(dw_gdma_ll_lli_set_src_addr, source)
SETTER(dw_gdma_ll_lli_set_src_burst_mode, mode)
SETTER(dw_gdma_ll_lli_set_src_burst_items, items)
SETTER(dw_gdma_ll_lli_set_src_burst_len, length)
SETTER(dw_gdma_ll_lli_set_trans_block_size, words)
SETTER(dw_gdma_ll_lli_set_next_item_addr, next)
static void dw_gdma_ll_lli_set_src_master_port(dw_gdma_link_list_item_t *n, uint32_t v) { (void)n; (void)v; }
#include "../../src/board/tab5/notice_sparse.h"

static void replay(void) {
    uint32_t words = 0;
    for (uint32_t i = 0; i < node_count; ++i) {
        const dw_gdma_link_list_item_t *n = notice_node(notice_active, i);
        const uint64_t *pixels = bank_pointer(n->source);
        for (uint32_t x = 0; x < n->words; ++x) {
            const uint64_t actual = pixels[n->mode == DW_GDMA_BURST_MODE_FIXED ? 0 : x];
            const uint64_t expected = i == 1 ? ((const uint64_t *)frame)[3 + x] : UINT64_C(0xf7bdf7bdf7bdf7bd);
            assert(actual == expected);
        }
        words += n->words;
        assert(n->next == (i + 1 == node_count ? 0 : notice_head(notice_active) + (i + 1) * 64));
    }
    assert(words == 230400);
}
int main(void) {
    _Static_assert(sizeof(descriptor) == 64, "mock hardware LLI size");
    ui.plan = 0x481f2000; ui.pixels = 0x48030000; ui.pixels_bytes = sizeof(frame);
    ui.capacity = 1280; ui.paper = 0xf7bd;
    plan[0] = (nih_ui_span){0, 0, 900, 0};
    plan[1] = (nih_ui_span){3, 24, 16, 0};
    plan[2] = (nih_ui_span){0, 0, 230400 - 916, 0};
    memset(frame, 0x31, sizeof(frame));
    assert(notice_build(0, 3)); notice_enabled = dma_owned = true; notice_activate(); replay();
    static uint8_t prior[sizeof(banks[0])]; memcpy(prior, banks[0], sizeof(prior));
    memset(frame, 0x52, sizeof(frame));
    assert(nih_display_notice_publish(3));
    assert(notice_active == 0 && notice_pending == 1 && notice_swaps == 0);
    assert(!memcmp(prior, banks[0], sizeof(prior)) && nih_display_notice_status() == 2);
    assert(!nih_display_notice_publish(3)); /* pending bank cannot be reused */
    notice_activate(); assert(notice_swaps == 1 && notice_active == 1); replay();
    assert(nih_display_notice_status() == 1);
    const unsigned before = handoffs;
    assert(!nih_display_notice_publish(0)); assert(!nih_display_notice_publish(1281));
    plan[1].kind = 4; assert(!nih_display_notice_publish(3)); plan[1].kind = 3;
    plan[1].offset = sizeof(frame); assert(!nih_display_notice_publish(3)); plan[1].offset = 24;
    plan[1].reserved = 1; assert(!nih_display_notice_publish(3)); plan[1].reserved = 0;
    plan[2].words++; assert(!nih_display_notice_publish(3)); plan[2].words--;
    const nih_ui_span saved = plan[0]; plan[0] = (nih_ui_span){3, 0, 230400, 0};
    assert(!nih_display_notice_publish(1)); plan[0] = saved; /* overfull bank */
    assert(handoffs == before && notice_active == notice_pending && notice_swaps == 1);
    cache_ok = false; assert(!nih_display_notice_publish(3));
    assert(notice_active == notice_pending && notice_swaps == 1); replay();
    cache_ok = true; memset(frame, 0x63, sizeof(frame));
    assert(nih_display_notice_publish(3)); notice_activate(); replay();
    fault = 1; assert(!nih_display_notice_publish(3)); assert(nih_display_notice_status() == 0);
    puts("Public notice bank replay passed: exact pixels, EOF publication, bounds, pending and cache failures");
}
