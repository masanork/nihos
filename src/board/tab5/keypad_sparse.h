/* Sparse keypad scanout, private to native_scanout.c. All descriptors are
 * held in explicit SRAM leases. Only text pixels/textures come from PSRAM. */
typedef struct { uint32_t kind, offset, words, reserved; } nih_ui_span;
typedef struct {
    uint32_t plan, count, peer_start, peer_bytes;
    uint32_t dots_x, dots_y, dots_width, dots_height;
    uint32_t label_x, label_y, label_width, label_height;
    uint32_t paper, keys, accent, scratch, stride, capacity;
} nih_ui_config;
_Static_assert(sizeof(nih_ui_span) == 16 && sizeof(nih_ui_config) == 72, "keypad ABI");
static nih_ui_config ui;
static uint32_t ui_local, ui_local_bytes, ui_split;
static uint64_t ui_palette[3] __attribute__((aligned(64)));
static uint32_t ui_dots[16], ui_labels[64], ui_submits[68];
static uint32_t ui_dot_count, ui_label_count, ui_submit_count;
static volatile uint32_t ui_active, ui_pending, ui_active_count, ui_pending_count;
static bool ui_enabled;

static bool ui_sram(uint32_t start, uint32_t bytes) {
    return !(start & 63) && bytes && !(bytes & 63) && start >= 0x4ff00000 &&
           start < 0x4ff28000 && bytes <= 0x4ff28000 - start;
}
static dw_gdma_link_list_item_t *ui_node(uint32_t index) {
    uint32_t start = index < ui_split ? ui_local : ui.peer_start;
    uint32_t offset = index < ui_split ? index : index - ui_split;
    return (dw_gdma_link_list_item_t *)(uintptr_t)(start + offset * 64);
}
bool nih_display_keypad_configure(const nih_ui_config *config) {
    if (dma_owned || !config || config->count == 0 || config->count > config->capacity ||
        config->count > 1024 || config->scratch != 0x481f2000 ||
        config->stride > (0x48200000 - config->scratch) / 2 || !config->stride ||
        config->plan < config->scratch + 2 * config->stride || config->plan >= 0x48200000 ||
        config->count > (0x48200000 - config->plan) / 16 || (config->plan & 63) ||
        !ui_sram(config->peer_start, config->peer_bytes) ||
        config->dots_width != 272 || config->dots_height != 16 || config->dots_x != 216 || config->dots_y != 390 ||
        config->label_width == 0 || config->label_width > 720 || (config->label_width & 3) ||
        config->label_height == 0 || config->label_height > 64 ||
        config->label_x > 720 - config->label_width || config->label_y > 1280 - config->label_height ||
        config->paper > 65535 || config->keys > 65535 || config->accent > 65535) return false;
    const uint32_t bytes = 272 * 16 * 2 + config->label_width * config->label_height * 2;
    if (bytes > config->stride) return false;
    ui = *config;
    ui_active = ui_pending = ui_active_count = ui_pending_count = 0;
    return true;
}
static uint32_t ui_source(uint32_t kind, uint32_t offset, uint32_t buffer, uint32_t count) {
    switch (kind) {
        case 0: return (uint32_t)(uintptr_t)&ui_palette[0];
        case 1: return (uint32_t)(uintptr_t)&ui_palette[1];
        case 2: return (uint32_t)(uintptr_t)&ui_palette[count == 4 ? 2 : 1];
        case 3: return 0x48030000 + offset;
        case 4: return ui.scratch + buffer * ui.stride + offset;
        case 5: return ui.scratch + buffer * ui.stride + 272 * 16 * 2 + offset;
        default: return 0;
    }
}
static int32_t ui_build(uint32_t local, uint32_t bytes) {
    if (!ui_sram(local, bytes) ||
        !(local + bytes <= ui.peer_start || ui.peer_start + ui.peer_bytes <= local) ||
        ui.count > (bytes + ui.peer_bytes) / 64) return -7;
    ui_local = local; ui_local_bytes = bytes; ui_split = bytes / 64;
    ui_dot_count = ui_label_count = ui_submit_count = 0;
    const uint32_t colors[3] = { ui.paper, ui.keys, ui.accent };
    for (uint32_t i = 0; i < 3; ++i) ui_palette[i] = (uint64_t)colors[i] * UINT64_C(0x0001000100010001);
    if (nih_rom_cache_writeback(1u << 4, (uint32_t)(uintptr_t)ui_palette, sizeof(ui_palette))) return -5;
    const nih_ui_span *plan = (const nih_ui_span *)(uintptr_t)ui.plan;
    uint32_t total = 0;
    for (uint32_t i = 0; i < ui.count; ++i) {
        const nih_ui_span span = plan[i];
        if (span.reserved || !span.words || span.words > 230400 - total || (span.offset & 7)) return -7;
        total += span.words;
        uint32_t limit = 0;
        if (span.kind < 3) { if (span.offset) return -7; }
        else {
            if (span.kind == 3) limit = 720 * 1280 * 2;
            else if (span.kind == 4) limit = 272 * 16 * 2;
            else if (span.kind == 5) limit = ui.label_width * ui.label_height * 2;
            else return -7;
            if (span.offset > limit || span.words > (limit - span.offset) / 8) return -7;
        }
        dw_gdma_link_list_item_t *node = ui_node(i);
        *node = descriptor;
        const uint32_t source = ui_source(span.kind, span.offset, 0, 0);
        dw_gdma_ll_lli_set_src_addr(node, source);
        dw_gdma_ll_lli_set_src_master_port(node, source);
        dw_gdma_ll_lli_set_src_burst_mode(node, span.kind < 3 ? DW_GDMA_BURST_MODE_FIXED : DW_GDMA_BURST_MODE_INCREMENT);
        dw_gdma_ll_lli_set_src_burst_items(node, span.kind < 3 ? DW_GDMA_BURST_ITEMS_1 : DW_GDMA_BURST_ITEMS_512);
        dw_gdma_ll_lli_set_src_burst_len(node, span.kind < 3 ? 1 : 16);
        dw_gdma_ll_lli_set_trans_block_size(node, span.words);
        dw_gdma_ll_lli_set_next_item_addr(node, i + 1 == ui.count ? 0 : (uint32_t)(uintptr_t)ui_node(i + 1));
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
    if (total != 230400 || ui_dot_count != 16 || ui_label_count != ui.label_height) return -7;
    active_nodes = ui_node(0); node_count = ui.count; source_address = (uint32_t)(uintptr_t)&ui_palette[0];
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
    return ui_enabled && ui_pending == ui_active ? 1u - ui_active : UINT32_MAX;
}
bool nih_display_keypad_publish(uint32_t buffer, uint32_t count) {
    if (!ui_enabled || count > 4 || buffer > 1 || buffer == ui_active || ui_pending != ui_active) return false;
    ui_pending_count = count;
    __asm__ volatile("fence rw,rw" ::: "memory");
    ui_pending = buffer;
    return true;
}
uint32_t nih_display_keypad_count(void) { return ui_active_count; }
