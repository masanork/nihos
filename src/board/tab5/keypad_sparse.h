/* Sparse keypad scanout, private to native_scanout.c. All descriptors are
 * held in dedicated SRAM pools. Immutable pixels copy from Flash once at boot. */
typedef struct { uint32_t kind, offset, words, reserved; } nih_ui_span;
#ifndef UI_INPUT
#define UI_INPUT(address) ((const void *)(uintptr_t)(address))
#endif
#ifndef UI_ADDRESS
#define UI_ADDRESS(pointer) ((uint32_t)(uintptr_t)(pointer))
#endif
#ifndef UI_OUTPUT
#define UI_OUTPUT(address) ((void *)(uintptr_t)(address))
#endif
#ifndef UI_NODE_POINTER
#define UI_NODE_POINTER(address) ((void *)((uintptr_t)(address) + SOC_NON_CACHEABLE_OFFSET))
#endif
#ifndef UI_PUBLISH_FENCE
#define UI_PUBLISH_FENCE() __asm__ volatile("fence rw,rw" ::: "memory")
#endif
#ifndef UI_FOREGROUND
#if NIH_NATIVE_CARD_READ
#define UI_FOREGROUND __attribute__((section(".flash.text.card")))
#else
#define UI_FOREGROUND
#endif
#endif
typedef struct {
    uint32_t plan, count, peer_start, peer_bytes;
    uint32_t dots_x, dots_y, dots_width, dots_height;
    uint32_t label_x, label_y, label_width, label_height;
    uint32_t paper, keys, accent, scratch, stride, capacity, pixels, pixels_bytes;
} nih_ui_config;
_Static_assert(sizeof(nih_ui_span) == 16 && sizeof(nih_ui_config) == 80, "keypad ABI");
/* Leased by the display service from the base allocator. */
static uint32_t ui_low_start, ui_low_end, ui_high_start, ui_high_end;
bool nih_display_keypad_memory(uint32_t low, uint32_t low_end, uint32_t high, uint32_t high_end) {
    if (dma_owned || !low || !high || low >= low_end || high >= high_end ||
        ((low | low_end | high | high_end) & 63) || !(low_end <= high || high_end <= low)) return false;
    ui_low_start = low; ui_low_end = low_end; ui_high_start = high; ui_high_end = high_end;
    return true;
}
static nih_ui_config ui;
static uint32_t ui_local, ui_local_bytes, ui_split;
static uint64_t ui_palette[3] __attribute__((aligned(64)));
static uint32_t ui_dots[16], ui_labels[64], ui_submits[68];
static uint32_t ui_dot_count, ui_label_count, ui_submit_count;
static volatile uint32_t ui_active, ui_pending, ui_active_count, ui_pending_count;
static bool ui_enabled;
static bool ui_runtime;

static bool ui_sram(uint32_t start, uint32_t bytes) {
    return !(start & 63) && bytes && !(bytes & 63) && start >= ui_low_start &&
           start < ui_low_end && bytes <= ui_low_end - start;
}
static UI_FOREGROUND bool ui_place(uint32_t length, uint32_t *upper, uint32_t *lower, uint32_t *target) {
    uint32_t *cursor = length <= ui_high_end - *upper ? upper : lower;
    const uint32_t end = cursor == upper ? ui_high_end : ui_low_end;
    if (*cursor > end || length > end - *cursor) return false;
    *target = *cursor; *cursor += length;
    return true;
}
/* Dry run before retirement. Reuse the same placement rule as ui_build;
 * read only CPU-owned plan/pixels and never touch the active SRAM scene. */
UI_FOREGROUND bool nih_display_keypad_fits(const nih_ui_config *c, uint32_t local, uint32_t bytes, bool notice) {
    if (!c || !c->count || c->count > c->capacity || !ui_sram(local, bytes) ||
        c->count > bytes / 64 || c->scratch != ui_low_start ||
        c->stride > (ui_low_end - ui_low_start) / 2 || local < c->scratch + 2 * c->stride) return false;
    uint32_t upper = ui_high_start, lower = local + bytes, total = 0;
    const uint32_t bank_bytes = ((ui_high_end - ui_high_start) / 2u) & ~63u;
    uint32_t used = 64 + c->count * 64;
    if (notice && used > bank_bytes) return false;
    const nih_ui_span *spans = UI_INPUT(c->plan);
    const uint64_t *previous[2] = {0}; uint32_t lengths[2] = {0};
    for (uint32_t i = 0; i < c->count; ++i) {
        const nih_ui_span s = spans[i];
        if (s.reserved || !s.words || s.words > 230400 - total || (s.offset & 7)) return false;
        total += s.words;
        if (notice && s.kind != 0 && s.kind != 3) return false;
        if (s.kind < 3) { if (s.offset) return false; continue; }
        const uint32_t limit = s.kind == 3 ? c->pixels_bytes : s.kind == 4 ? 272 * 16 * 2 :
                               s.kind == 5 ? c->label_width * c->label_height * 2 : 0;
        if (!limit || s.offset > limit || s.words > (limit - s.offset) / 8) return false;
        if (s.kind != 3) continue;
        const uint32_t length = s.words * 8;
        if (notice) {
            if (length > bank_bytes - used) return false;
            used += length; continue;
        }
        const bool runtime = NIH_NATIVE_CARD_READ;
        const uint32_t group = runtime && s.offset % 1440 >= 912 && s.offset / 1440 >= 192 && s.offset / 1440 < 448;
        const uint64_t *source = UI_INPUT(c->pixels + s.offset);
        bool repeated = runtime && length == lengths[group];
        for (uint32_t n = 0; repeated && n < s.words; ++n) if (source[n] != previous[group][n]) repeated = false;
        previous[group] = source; lengths[group] = length;
        uint32_t target;
        if (!repeated && !ui_place(length, &upper, &lower, &target)) return false;
    }
    return total == 230400;
}
static uint32_t ui_node_address(uint32_t index) {
    uint32_t start = index < ui_split ? ui_local : ui.peer_start;
    uint32_t offset = index < ui_split ? index : index - ui_split;
    return start + offset * 64;
}
static dw_gdma_link_list_item_t *ui_node(uint32_t index) {
    return UI_NODE_POINTER(ui_node_address(index));
}
bool nih_display_keypad_configure(const nih_ui_config *config) {
    const bool runtime = NIH_NATIVE_CARD_READ && config && config->pixels == 0x48030000 && config->pixels_bytes == 720 * 1280 * 2 &&
                         config->plan == 0x481f2000 && config->count <= (0x48200000 - 0x481f2000) / 16;
    if (dma_owned || !config || config->count == 0 || config->count > config->capacity ||
        config->count > (NIH_NATIVE_CARD_READ ? 1280u : 1024u) || config->scratch != ui_low_start ||
        config->stride > (ui_low_end - config->scratch) / 2 || (!config->stride && config->label_height) ||
        (!runtime && (config->plan < 0x40020000 || config->plan >= 0x400c0000 ||
        config->count > (0x400c0000 - config->plan) / 16 || (config->plan & 63) ||
        config->pixels < 0x40020000 || config->pixels >= 0x400c0000 ||
        config->pixels_bytes > 0x400c0000 - config->pixels || (config->pixels & 63))) ||
        config->peer_start != 0 || config->peer_bytes != 0 ||
        config->dots_width != 272 || config->dots_height != 16 || config->dots_x != 216 || config->dots_y != 390 ||
        config->label_width == 0 || config->label_width > 720 || (config->label_width & 3) ||
        config->label_height > 64 ||
        config->label_x > 720 - config->label_width || config->label_y > 1280 - config->label_height ||
        config->paper > 65535 || config->keys > 65535 || config->accent > 65535) return false;
    const uint32_t bytes = config->label_height ? 272 * 16 * 2 + config->label_width * config->label_height * 2 : 0;
    if (bytes > config->stride) return false;
    ui = *config;
    ui_runtime = runtime;
    ui_active = ui_pending = ui_active_count = ui_pending_count = 0;
    return true;
}
static uint32_t ui_source(uint32_t kind, uint32_t offset, uint32_t buffer, uint32_t count) {
    switch (kind) {
        case 0: return UI_ADDRESS(&ui_palette[0]);
        case 1: return UI_ADDRESS(&ui_palette[1]);
        case 2: return UI_ADDRESS(&ui_palette[count == 4 ? 2 : 1]);
        case 3: return ui.pixels + offset;
        case 4: return ui.scratch + buffer * ui.stride + offset;
        case 5: return ui.scratch + buffer * ui.stride + 272 * 16 * 2 + offset;
        default: return 0;
    }
}
static int32_t ui_build(uint32_t local, uint32_t bytes) {
    if (!ui_sram(local, bytes) || local < ui.scratch + 2 * ui.stride || ui.count > bytes / 64) return -7;
    ui_local = local; ui_local_bytes = bytes; ui_split = bytes / 64;
    /* Match IDF's DW-GDMA ownership handoff: flush/invalidate once, then
     * never mix cached CPU LLI stores with the device's valid-bit writeback. */
    if (nih_rom_cache_writeback(1u << 4, local, bytes) ||
        nih_rom_cache_invalidate(1u << 4, local, bytes)) return -5;
    ui_dot_count = ui_label_count = ui_submit_count = 0;
    const uint32_t colors[3] = { ui.paper, ui.keys, ui.accent };
    for (uint32_t i = 0; i < 3; ++i) ui_palette[i] = (uint64_t)colors[i] * UINT64_C(0x0001000100010001);
    if (nih_rom_cache_writeback(1u << 4, UI_ADDRESS(ui_palette), sizeof(ui_palette))) return -5;
    const nih_ui_span *plan = UI_INPUT(ui.plan);
    uint32_t total = 0;
    uint32_t upper = ui_high_start;
    uint32_t lower = local + bytes;
    uint32_t atlas_offset = 0;
    uint32_t previous_sources[2] = {0}, previous_targets[2] = {0}, previous_lengths[2] = {0};
    for (uint32_t i = 0; i < ui.count; ++i) {
        const nih_ui_span span = plan[i];
        if (span.reserved || !span.words || span.words > 230400 - total || (span.offset & 7)) return -7;
        total += span.words;
        uint32_t limit = 0;
        if (span.kind < 3) { if (span.offset) return -7; }
        else {
            if (span.kind == 3) limit = ui.pixels_bytes;
            else if (span.kind == 4) limit = 272 * 16 * 2;
            else if (span.kind == 5) limit = ui.label_width * ui.label_height * 2;
            else return -7;
            if (span.offset > limit || span.words > (limit - span.offset) / 8) return -7;
        }
        dw_gdma_link_list_item_t *node = ui_node(i);
        *node = descriptor;
        uint32_t source = ui_source(span.kind, span.offset, 0, 0);
        if (span.kind == 3) {
            const uint32_t length = span.words * 8;
            if (!ui_runtime && span.offset != atlas_offset) return -7;
            atlas_offset += length;
            const uint32_t group = ui_runtime && (span.offset % 1440 >= 912) && span.offset / 1440 >= 192 && span.offset / 1440 < 448;
            uint32_t *previous_source = &previous_sources[group], *previous_target = &previous_targets[group], *previous_length = &previous_lengths[group];
            const uint64_t *src = UI_INPUT(source);
            bool repeated = ui_runtime && length == *previous_length;
            const uint64_t *previous = UI_INPUT(*previous_source);
            for (uint32_t n = 0; repeated && n < span.words; ++n) if (src[n] != previous[n]) repeated = false;
            if (repeated) {
                *previous_source = source;
                source = *previous_target;
            } else {
                *previous_source = source;
                *previous_length = length;
                uint32_t target;
                if (!ui_place(length, &upper, &lower, &target)) return -7;
                uint64_t *dst = UI_OUTPUT(target);
                for (uint32_t n = 0; n < span.words; ++n) dst[n] = src[n];
                source = target;
                *previous_target = source;
            }
        }
        dw_gdma_ll_lli_set_src_addr(node, source);
        dw_gdma_ll_lli_set_src_master_port(node, source);
        dw_gdma_ll_lli_set_src_burst_mode(node, span.kind < 3 ? DW_GDMA_BURST_MODE_FIXED : DW_GDMA_BURST_MODE_INCREMENT);
        dw_gdma_ll_lli_set_src_burst_items(node, span.kind < 3 ? DW_GDMA_BURST_ITEMS_1 : DW_GDMA_BURST_ITEMS_512);
        dw_gdma_ll_lli_set_src_burst_len(node, span.kind < 3 ? 1 : 16);
        dw_gdma_ll_lli_set_trans_block_size(node, span.words);
        dw_gdma_ll_lli_set_next_item_addr(node, i + 1 == ui.count ? 0 : ui_node_address(i + 1));
        if (span.kind == 2) {
            if (ui_submit_count == 68) return -7;
            ui_submits[ui_submit_count++] = i;
        } else if (span.kind == 4) {
            if (ui_dot_count == 16 || span.offset != ui_dot_count * 272 * 2 || span.words != 272 / 4) return -7;
            ui_dots[ui_dot_count++] = i;
        } else if (span.kind == 5) {
            if (ui_label_count == 64 || span.offset != ui_label_count * ui.label_width * 2 || span.words != ui.label_width / 4) return -7;
            ui_labels[ui_label_count++] = i;
        }
    }
    if (total != 230400 || (!ui_runtime && atlas_offset != ui.pixels_bytes) || (ui.label_height && ui_dot_count != 16) || ui_label_count != ui.label_height) return -7;
    if (nih_rom_cache_writeback(1u << 4, ui_high_start, upper - ui_high_start) ||
        (lower > local + bytes && nih_rom_cache_writeback(1u << 4, local + bytes, lower - local - bytes))) return -5;
    active_nodes = ui_node(0); node_count = ui.count; source_address = UI_ADDRESS(&ui_palette[0]);
    ui_enabled = true;
    return 0;
}
static void ui_activate(void) {
    if (ui_active == ui_pending) return;
    const uint32_t next = ui_pending;
    const uint32_t count = ui_pending_count;
    for (uint32_t y = 0; y < ui_dot_count; ++y)
        dw_gdma_ll_lli_set_src_addr(ui_node(ui_dots[y]), ui_source(4, y * 272 * 2, next, count));
    for (uint32_t y = 0; y < ui_label_count; ++y)
        dw_gdma_ll_lli_set_src_addr(ui_node(ui_labels[y]), ui_source(5, y * ui.label_width * 2, next, count));
    for (uint32_t i = 0; i < ui_submit_count; ++i)
        dw_gdma_ll_lli_set_src_addr(ui_node(ui_submits[i]), ui_source(2, 0, next, count));
    ui_active_count = count;
    ui_active = next;
}
uint32_t nih_display_keypad_buffer(void) {
    return ui_enabled && ui.label_height && ui_pending == ui_active ? 1u - ui_active : UINT32_MAX;
}
bool nih_display_keypad_publish(uint32_t buffer, uint32_t count) {
    if (!ui_enabled || !ui.label_height || count > 4 || buffer > 1 || buffer == ui_active || ui_pending != ui_active) return false;
    ui_pending_count = count;
    UI_PUBLISH_FENCE();
    ui_pending = buffer;
    return true;
}
uint32_t nih_display_keypad_count(void) { return ui_active_count; }
