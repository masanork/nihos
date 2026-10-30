#ifdef NDEBUG
#error "Host replay requires active assertions"
#endif
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "hal/dw_gdma_ll.h"
dw_gdma_dev_t DW_GDMA;
hp_sys_clkrst_dev_t HP_SYS_CLKRST;
static bool enabled, stuck, complete, corrupt, mark_ok = true;
static uint32_t common;
static uint8_t external_destination[64] __attribute__((aligned(64)));
static void fake_enable(bool on);
static void fake_clear(uint32_t events) { DW_GDMA.ch[1].int_st0.val &= ~events; }
#define TEST_DMA_ENABLE(on) fake_enable(on)
#define TEST_DMA_ENABLED() enabled
#define TEST_DMA_CLEAR(bits) fake_clear(bits)
#define TEST_DMA_FENCE() ((void)0)
#define TEST_CACHE_LOCK(previous) ((previous) = 0)
#define TEST_CACHE_UNLOCK(previous) ((void)(previous))
int32_t nih_rom_cache_writeback(uint32_t mask, uint32_t addr, uint32_t len) { (void)mask; (void)addr; (void)len; return 0; }
int32_t nih_rom_cache_invalidate(uint32_t mask, uint32_t addr, uint32_t len) { (void)mask; (void)addr; (void)len; return 0; }
bool nih_camera_dma_domain_mark_started(uint32_t token) { return mark_ok && token == 9; }
bool nih_camera_dma_domain_common(uint32_t token, uint32_t *out) { if (token != 9) return false; *out = common; return true; }
#include "../../src/board/tab5/native_camera_dma_test.c"
static void fake_enable(bool on) {
    if (!on && stuck) return;
    enabled = on;
    if (on && complete) {
        memcpy(destination, source, BYTES);
        if (corrupt) destination[7] ^= 1;
        DW_GDMA.ch[1].int_st0.val = DONE;
    }
}
static void reset(void) {
    memset(&DW_GDMA, 0, sizeof(DW_GDMA));
    DW_GDMA.cfg0.dmac_en = 1;
    DW_GDMA.ch[0].int_sig_ena0.val = 0x12345678;
    enabled = stuck = complete = corrupt = false;
    common = events = token = 0;
    used = active = false;
    mark_ok = true;
}
int main(void) {
    reset(); complete = true;
    assert(nih_camera_dma_test_begin(9));
    assert(nih_camera_dma_test_poll(false) == 1);
    assert(!enabled && used && !active && DW_GDMA.ch[0].int_sig_ena0.val == 0x12345678);
    assert(!nih_camera_dma_test_begin(9));
    reset(); assert(nih_camera_dma_test_begin(9));
    assert(nih_camera_dma_test_poll(false) == 0);
    assert(nih_camera_dma_test_poll(true) == -2 && !enabled);
    reset(); complete = true; corrupt = true;
    assert(nih_camera_dma_test_begin(9) && nih_camera_dma_test_poll(false) == -4);
    reset(); complete = true; stuck = true;
    assert(nih_camera_dma_test_begin(9) && nih_camera_dma_test_poll(false) == -2);
    assert(enabled && used && !active);
    reset(); complete = true; common = 1;
    assert(nih_camera_dma_test_begin(9) && nih_camera_dma_test_poll(false) == -2);
    reset(); mark_ok = false;
    assert(!nih_camera_dma_test_begin(9) && !enabled);
    reset(); complete = true;
    assert(!nih_camera_dma_psram_test_begin(9, 0x48030001));
    assert(!nih_camera_dma_psram_test_begin(9, 0x4802ffc0));
    assert(begin_to(9, external_destination));
    assert(nih_camera_dma_test_poll(false) == 1);
    assert(external_destination[17] == (uint8_t)(17u * 37u + 13u));
    puts("Camera DMA memory transfer replay passed");
}
