/* Host replay of production channel-1 control and injected stuck hardware. */
#ifdef NDEBUG
#error "Host replay requires active assertions"
#endif
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "hal/dw_gdma_ll.h"
#include "hal/mipi_csi_brg_ll.h"
#include "hal/mipi_csi_ll.h"
dw_gdma_dev_t DW_GDMA;
hp_sys_clkrst_dev_t HP_SYS_CLKRST;
csi_brg_dev_t MIPI_CSI_BRIDGE;
csi_host_dev_t MIPI_CSI_HOST;
static bool enabled, stuck;
static void fake_enable(bool on) { if (on || !stuck) enabled = on; }
static void fake_clear(uint32_t events) { DW_GDMA.ch[1].int_st0.val &= ~events; }
#define CSI_DMA_ENABLE(on) fake_enable(on)
#define CSI_DMA_ENABLED() enabled
#define CSI_DMA_CLEAR(events) fake_clear(events)
#define CSI_DMA_FENCE() ((void)0)
#include "../../src/board/tab5/native_csi_dma_run.c"
int main(void) {
    csi_rx rx = {0};
    DW_GDMA.cfg0.dmac_en = 1;
    HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_brg_sys_clk_en = 1;
    DW_GDMA.ch[0].int_sig_ena0.val = 0x12345678;
    assert(nih_csi_dma_arm(&rx));
    assert(rx.state == CSI_RX_ARMED && enabled);
    assert(nih_csi_dma_bridge_on(&rx));
    MIPI_CSI_HOST.phy_rx.val = 0x20000;
    MIPI_CSI_BRIDGE.int_raw.val = 0x10;
    DW_GDMA.ch[1].status0.cmpltd_blk_tfr_size = 17;
    DW_GDMA.ch[1].dar0.dar0 = 0x48030100;
    assert(nih_csi_dma_observe(9) == 0x48030100);
    assert(nih_csi_dma_observe(0) == 0x20000 && nih_csi_dma_observe(1) == 0x10 && nih_csi_dma_observe(2) == 17);
    DW_GDMA.ch[1].int_st0.val = CSI_DMA_DONE;
    assert(nih_csi_dma_poll(&rx, 0) == CSI_DMA_DONE);
    DW_GDMA.ch[1].int_st0.val = (1u << 5) | (1u << 30);
    assert(nih_csi_dma_stop(&rx));
    assert(nih_csi_dma_observe(8) == ((1u << 5) | (1u << 30)));
    assert(rx.state == CSI_RX_STOPPED && !enabled && !MIPI_CSI_BRIDGE.csi_en.csi_brg_en);
    assert((rx.events & CSI_DMA_ERRORS) != 0); /* late fault not lost */
    assert(DW_GDMA.ch[0].int_sig_ena0.val == 0x12345678);
    uint32_t late = 0;
    assert(nih_csi_dma_window_poll(&rx, &late) && !late);
    DW_GDMA.ch[1].int_st0.val = 1u << 5; /* negative control */
    assert(nih_csi_dma_window_poll(&rx, &late) && late == (1u << 5));
    assert(nih_csi_dma_window_finish() == (1u << 5));
    assert(!nih_csi_dma_window_poll(&rx, &late)); /* generation disabled */
    assert(nih_csi_dma_retained_ready()); /* caller still rejects rx's latched fault */
    enabled = true;
    assert(!nih_csi_dma_retained_ready());
    enabled = false;
    DW_GDMA.ch[1].int_st0.val = CSI_DMA_DONE;
    assert(!nih_csi_dma_retained_ready());
    DW_GDMA.ch[1].int_st0.val = 0;
    MIPI_CSI_BRIDGE.csi_en.csi_brg_en = 1;
    assert(!nih_csi_dma_retained_ready());
    HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_brg_sys_clk_en = 0;
    assert(nih_csi_dma_retained_ready()); /* don't read a clock-gated bridge */
    HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_brg_sys_clk_en = 1;
    MIPI_CSI_BRIDGE.csi_en.csi_brg_en = 0;
    DW_GDMA.ch[1].int_sig_ena0.val = 2;
    assert(!nih_csi_dma_retained_ready());
    DW_GDMA.ch[1].int_sig_ena0.val = 0;
    DW_GDMA.ch[1].int_st_ena0.val = 2;
    assert(!nih_csi_dma_retained_ready());
    DW_GDMA.ch[1].int_st_ena0.val = 0;
    assert(nih_csi_dma_retained_ready());
    assert(DW_GDMA.ch[0].int_sig_ena0.val == 0x12345678);
    rx = (csi_rx){0};
    assert(nih_csi_dma_arm(&rx) && nih_csi_dma_bridge_on(&rx));
    stuck = true;
    assert(!nih_csi_dma_stop(&rx) && rx.state == CSI_RX_PINNED);
    assert(!nih_csi_dma_arm(&rx));
    stuck = false;
    assert(!nih_csi_dma_stop(&rx) && rx.state == CSI_RX_PINNED); /* pinned until reboot */
    rx = (csi_rx){0};
    assert(nih_csi_dma_arm(&rx) && nih_csi_dma_bridge_on(&rx));
    DW_GDMA.ch[1].int_st0.val = CSI_DMA_DONE;
    assert((nih_csi_dma_poll(&rx, 1) & CSI_DMA_ERRORS) != 0);
    assert(nih_csi_dma_stop(&rx));
    puts("CSI DMA one-frame control replay passed");
}
