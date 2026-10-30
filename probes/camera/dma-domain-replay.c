/* Actual shared-domain and camera lease policy with mock register behavior. */
#ifdef NDEBUG
#error "Host replay requires active assertions"
#endif
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
typedef struct { uint32_t val; } reg;
typedef struct { reg int_sig_ena0, int_st_ena0, int_st0; uint32_t fifo; } channel;
static struct { reg chen0; channel ch[4]; } DW_GDMA;
static bool clocked;
static uint32_t status, resets;
static void dw_gdma_ll_enable_bus_clock(unsigned n, bool on) { assert(n == 0); clocked = on; }
static bool dw_gdma_ll_is_bus_clock_enabled(unsigned n) { assert(n == 0); return clocked; }
static void dw_gdma_ll_reset_register(unsigned n) { assert(n == 0); ++resets; }
static void dw_gdma_ll_enable_controller(void *d, bool b) { (void)d; (void)b; }
static void dw_gdma_ll_enable_intr_global(void *d, bool b) { (void)d; (void)b; }
static void dw_gdma_ll_enable_common_intr_generation(void *d, uint32_t m, bool b) { (void)d; (void)m; (void)b; }
static void dw_gdma_ll_enable_common_intr_propagation(void *d, uint32_t m, bool b) { (void)d; (void)m; (void)b; }
static uint32_t dw_gdma_ll_get_common_intr_status(void *d) { (void)d; return status; }
static void dw_gdma_ll_clear_common_intr(void *d, uint32_t m) { (void)d; status &= ~m; }
static uint32_t dw_gdma_ll_channel_get_intr_status(void *d, unsigned n) { (void)d; return DW_GDMA.ch[n].int_st0.val; }
static uint32_t dw_gdma_ll_channel_get_fifo_remain(void *d, unsigned n) { (void)d; return DW_GDMA.ch[n].fifo; }
#include "../../src/board/tab5/dw_dma_domain.h"
#include "../../src/board/tab5/dw_dma_camera.h"
int main(void) {
    assert(dw_camera_acquire() == 0); /* no display owner, clock remains off */
    assert(!clocked);
    assert(dw_domain_acquire(0) && clocked && resets == 1);
    DW_GDMA.chen0.val = 2;
    assert(dw_camera_acquire() == 0);
    DW_GDMA.chen0.val = 0;
    DW_GDMA.ch[1].fifo = 1;
    assert(dw_camera_acquire() == 0);
    DW_GDMA.ch[1].fifo = 0;
    /* P4 resets these enable registers to ones, even with an idle channel. */
    DW_GDMA.ch[1].int_sig_ena0.val = 0x7fffffb;
    DW_GDMA.ch[1].int_st_ena0.val = 0x7fffffb;
    uint32_t first = dw_camera_acquire();
    assert(first && !dw_camera_acquire() && resets == 1);
    assert(!dw_camera_release_unused(first + 1));
    DW_GDMA.ch[1].int_sig_ena0.val = 1;
    assert(!dw_camera_release_unused(first));
    DW_GDMA.ch[1].int_sig_ena0.val = 0x7fffffb;
    assert(dw_camera_release_unused(first) && clocked && dw_domain_channels == 1);
    uint32_t second = dw_camera_acquire();
    assert(second && second != first);
    uint32_t common = 0;
    assert(!dw_camera_common(first, &common));
    assert(dw_camera_common(second, &common) && common == 0);
    status = 0x40;
    assert(!dw_camera_release_unused(second)); /* fault arrived after last poll */
    assert(dw_camera_common(second, &common) && common == 0x40);
    assert(dw_domain_take_common(0) == 0x40);
    assert(!dw_camera_release_unused(second)); /* fault retains lease */
    assert(!dw_camera_mark_started(second));
    /* New isolated boot for the started-but-not-qualified retirement case. */
    dw_camera_live = dw_camera_fault = 0; dw_domain_channels = 1; dw_domain_common_fault = false;
    uint32_t third = dw_camera_acquire();
    assert(third && dw_camera_mark_started(third));
    assert(!dw_camera_release_unused(third));
    assert(clocked && dw_domain_channels == 3);
    puts("Camera DMA domain lease replay passed");
}
