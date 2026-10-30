#ifdef NDEBUG
#error "Host replay requires active assertions"
#endif
#include <stdlib.h>
#include <assert.h>
#include <stdio.h>
#include "hal/dw_gdma_ll.h"
#include "hal/mipi_csi_brg_ll.h"
dw_gdma_dev_t DW_GDMA;
csi_brg_dev_t MIPI_CSI_BRIDGE;
static bool active = true;
static uint32_t last_clear;
static void clear(uint32_t mask) { last_clear = mask; DW_GDMA.ch[1].int_st0.val &= ~mask; }
static void disable(void) { active = false; }
#define INFLIGHT_ENABLED() active
#define INFLIGHT_CLEAR(mask) clear(mask)
#define INFLIGHT_DISABLE() disable()
#define INFLIGHT_FENCE() ((void)0)
#include "../../src/board/tab5/native_csi_inflight_adapter.c"
int main(void) {
    DW_GDMA.ch[0].int_st0.val = 0x12345678;
    DW_GDMA.ch[1].int_st_ena0.val = 0xffffffff;
    DW_GDMA.ch[1].int_sig_ena0.val = 0x07c08004; /* reserved/RO readback */
    DW_GDMA.ch[1].int_st0.val = DISABLED | (1u << 5);
    assert(nih_csi_inflight_active() && nih_csi_inflight_generation() && nih_csi_inflight_masked());
    nih_csi_inflight_clear_disabled();
    assert(last_clear == DISABLED && nih_csi_inflight_status() == (1u << 5));
    assert(DW_GDMA.ch[0].int_st0.val == 0x12345678);
    assert(!nih_csi_inflight_request_disable() && active); /* concurrent error */
    DW_GDMA.ch[1].int_st0.val = 2;
    assert(!nih_csi_inflight_request_disable() && active); /* completed */
    DW_GDMA.ch[1].int_st0.val = 0;
    MIPI_CSI_BRIDGE.csi_en.csi_brg_en = 1;
    assert(!nih_csi_inflight_request_disable());
    assert(nih_csi_inflight_bridge_off());
    DW_GDMA.ch[1].int_st_ena0.val &= ~DISABLED;
    assert(!nih_csi_inflight_request_disable());
    DW_GDMA.ch[1].int_st_ena0.val |= DISABLED;
    DW_GDMA.ch[1].int_sig_ena0.val |= 2;
    assert(!nih_csi_inflight_request_disable());
    DW_GDMA.ch[1].int_sig_ena0.val &= ~2u;
    assert(nih_csi_inflight_request_disable() && !nih_csi_inflight_active());
    assert(!nih_csi_inflight_request_disable());
    DW_GDMA.ch[1].status1.data_left_in_fifo = 3;
    assert(nih_csi_inflight_fifo() == 3);
    puts("CSI in-flight register adapter replay passed");
}
