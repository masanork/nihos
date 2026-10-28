/* Card-free diagnostic: compare the pixels DMA actually borrows (uncached
 * SRAM), in descriptor order, with the CPU's staged RGB565 framebuffer.
 * Never print pixels; only the mismatch count leaves this function. */
#if NIH_NATIVE_CARD_AUTO && NIH_NATIVE_CARD_SCENE_EXERCISE
#ifndef SCENE_ACTUAL
#define SCENE_ACTUAL(address) ((const volatile uint64_t *)((uintptr_t)(address) + SOC_NON_CACHEABLE_OFFSET))
#define SCENE_EXPECTED(address) ((const uint64_t *)(uintptr_t)(address))
#define SCENE_FOREGROUND __attribute__((section(".flash.photo")))
#endif
SCENE_FOREGROUND uint32_t nih_display_scene_mismatches(uint32_t address) {
    if (!dma_owned || fault || address != 0x48030000 || !node_count || node_count > 1280 ||
        (!ui_enabled && !notice_enabled)) return UINT32_MAX;
    const uint64_t *expected = SCENE_EXPECTED(address);
    uint32_t at = 0, mismatches = 0;
    for (uint32_t i = 0; i < node_count; ++i) {
        const dw_gdma_link_list_item_t *node = ui_enabled ? ui_node(i) : &active_nodes[i];
        const uint32_t words = node->block_ts_lo.block_ts + 1;
        const uint32_t src = node->sar_lo.sar0;
        const bool fixed = node->ctrl_lo.sinc == DW_GDMA_BURST_MODE_FIXED;
        if (!words || words > 230400 - at || (src & 7) || node->sar_hi.val ||
            node->ctrl_lo.src_tr_width != DW_GDMA_TRANS_WIDTH_64 ||
            (!fixed && node->ctrl_lo.sinc != DW_GDMA_BURST_MODE_INCREMENT)) return UINT32_MAX;
        const uint32_t bytes = fixed ? 8 : words * 8;
        if (!scene_source_allowed(src, bytes)) return UINT32_MAX;
        const volatile uint64_t *actual = SCENE_ACTUAL(src);
        for (uint32_t n = 0; n < words; ++n)
            if (actual[fixed ? 0 : n] != expected[at + n]) ++mismatches;
        at += words;
    }
    return at == 230400 ? mismatches : UINT32_MAX;
}
#endif
