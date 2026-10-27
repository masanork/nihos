/* Public status messages only. Two banks in the existing upper SRAM pool;
 * the live bank is immutable until the DMA frame-completion handoff. */
#if NIH_NATIVE_CARD_AUTO
#define NOTICE_BASE 0x4ff70000u
#define NOTICE_BYTES (94u * 1024u)
#ifndef NOTICE_POINTER
#define NOTICE_POINTER(address) ((void *)((uintptr_t)(address) + SOC_NON_CACHEABLE_OFFSET))
#endif
#ifndef NOTICE_INPUT
#define NOTICE_INPUT(address) ((const void *)(uintptr_t)(address))
#endif
#ifndef NOTICE_FOREGROUND
#define NOTICE_FOREGROUND __attribute__((section(".flash.photo")))
#endif
static volatile uint32_t notice_active, notice_pending;
static uint32_t notice_nodes[2];
static bool notice_enabled;
static uint32_t notice_swaps;

static uint32_t notice_head(uint32_t bank) { return NOTICE_BASE + bank * NOTICE_BYTES + 64; }
static dw_gdma_link_list_item_t *notice_node(uint32_t bank, uint32_t index) {
    return NOTICE_POINTER(notice_head(bank) + index * 64);
}
static NOTICE_FOREGROUND bool notice_build(uint32_t bank, uint32_t count) {
    if (bank > 1 || !count || count > ui.capacity || count > 1280 ||
        ui.plan != 0x481f2000 || ui.pixels != 0x48030000 || ui.pixels_bytes != 1843200 ||
        ui.label_height || !ui_runtime) return false;
    const nih_ui_span *plan = NOTICE_INPUT(ui.plan);
    uint32_t total = 0, used = 64 + count * 64;
    if (used > NOTICE_BYTES) return false;
    /* Validate the entire candidate before touching even the inactive bank. */
    for (uint32_t i = 0; i < count; ++i) {
        const nih_ui_span s = plan[i];
        if (s.reserved || !s.words || s.words > 230400 - total ||
            (s.kind != 0 && s.kind != 3) || (s.offset & 7)) return false;
        total += s.words;
        if (s.kind == 0) { if (s.offset) return false; }
        else {
            if (s.offset > ui.pixels_bytes || s.words > (ui.pixels_bytes - s.offset) / 8 ||
                s.words > (NOTICE_BYTES - used) / 8) return false;
            used += s.words * 8;
        }
    }
    if (total != 230400) return false;
    const uint32_t base = NOTICE_BASE + bank * NOTICE_BYTES;
    /* Only the inactive bank changes ownership. All following stores use the
     * noncached alias, including descriptor valid-bit state shared with DMA. */
    if (!notice_cache_handoff(base, NOTICE_BYTES)) return false;
    *(uint64_t *)NOTICE_POINTER(base) = (uint64_t)ui.paper * UINT64_C(0x0001000100010001);
    uint32_t pixel = base + 64 + count * 64;
    for (uint32_t i = 0; i < count; ++i) {
        const nih_ui_span s = plan[i];
        dw_gdma_link_list_item_t *node = notice_node(bank, i);
        *node = descriptor;
        uint32_t source = base;
        if (s.kind == 3) {
            const uint64_t *src = NOTICE_INPUT(ui.pixels + s.offset);
            uint64_t *dst = NOTICE_POINTER(pixel);
            for (uint32_t n = 0; n < s.words; ++n) dst[n] = src[n];
            source = pixel; pixel += s.words * 8;
        }
        dw_gdma_ll_lli_set_src_addr(node, source);
        dw_gdma_ll_lli_set_src_master_port(node, source);
        dw_gdma_ll_lli_set_src_burst_mode(node, s.kind == 0 ? DW_GDMA_BURST_MODE_FIXED : DW_GDMA_BURST_MODE_INCREMENT);
        dw_gdma_ll_lli_set_src_burst_items(node, s.kind == 0 ? DW_GDMA_BURST_ITEMS_1 : DW_GDMA_BURST_ITEMS_512);
        dw_gdma_ll_lli_set_src_burst_len(node, s.kind == 0 ? 1 : 16);
        dw_gdma_ll_lli_set_trans_block_size(node, s.words);
        dw_gdma_ll_lli_set_next_item_addr(node, i + 1 == count ? 0 : notice_head(bank) + (i + 1) * 64);
    }
    notice_nodes[bank] = count;
    return true;
}
static void notice_activate(void) {
    if (notice_active != notice_pending) ++notice_swaps;
    notice_active = notice_pending;
    active_nodes = notice_node(notice_active, 0);
    node_count = notice_nodes[notice_active];
    source_address = NOTICE_BASE + notice_active * NOTICE_BYTES;
}
NOTICE_FOREGROUND bool nih_display_notice_publish(uint32_t count) {
    if (!dma_owned || fault || !notice_enabled || notice_pending != notice_active) return false;
    const uint32_t next = 1u - notice_active;
    if (!notice_build(next, count)) return false;
    __asm__ volatile("" ::: "memory");
    notice_publish_fence();
    notice_pending = next;
    return true;
}
uint32_t nih_display_notice_status(void) {
    return !notice_enabled || !dma_owned || fault ? 0 : notice_pending == notice_active ? 1 : 2;
}
#else
uint32_t nih_display_notice_status(void) { return 0; }
#endif
