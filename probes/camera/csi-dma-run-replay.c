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
static void fake_bridge_clear(uint32_t events) {
    MIPI_CSI_BRIDGE.int_clr.val = events;
    MIPI_CSI_BRIDGE.int_raw.val &= ~events;
}
#define CSI_DMA_ENABLE(on) fake_enable(on)
#define CSI_DMA_ENABLED() enabled
#define CSI_DMA_CLEAR(events) fake_clear(events)
#define CSI_DMA_FENCE() ((void)0)
#define CSI_BRIDGE_CLEAR(events) fake_bridge_clear(events)
#include "../../src/board/tab5/native_csi_dma_config.c"
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
    MIPI_CSI_BRIDGE.int_raw.val = 0;
    assert(nih_csi_stream_begin(0x48200000u, 0x48400000u));
    rx = (csi_rx){0};
    assert(nih_csi_dma_arm(&rx) && nih_csi_dma_bridge_on(&rx));
    uint32_t rejected_generation = 0;
    for (unsigned i = 0; i < 3; ++i) {
        MIPI_CSI_BRIDGE.int_raw.val = 0x24u;
        DW_GDMA.ch[1].int_st0.val = CSI_DMA_DONE;
        nih_csi_stream_irq(0);
        assert(!nih_csi_stream_state(3) && nih_csi_stream_state(5) == i + 1);
        assert(nih_csi_stream_state(1) == 0 && nih_csi_stream_borrow(&rejected_generation) == 0);
        assert(DW_GDMA.ch[1].dar0.dar0 == 0x48200000u);
        assert(MIPI_CSI_BRIDGE.int_clr.val == 4u && MIPI_CSI_BRIDGE.int_raw.val == 0x20u);
    }
    DW_GDMA.ch[1].int_st0.val = CSI_DMA_DONE;
    nih_csi_stream_irq(0);
    uint32_t generation = 0;
    assert(nih_csi_stream_borrow(&generation) == 0x48200000u && generation == 1);
    assert(DW_GDMA.ch[1].dar0.dar0 == 0x48400000u);
    MIPI_CSI_BRIDGE.int_raw.val = 4u;
    DW_GDMA.ch[1].int_st0.val = CSI_DMA_DONE;
    nih_csi_stream_irq(0);
    assert(!nih_csi_stream_state(3) && nih_csi_stream_state(5) == 4u);
    assert(nih_csi_stream_state(1) == 1 && DW_GDMA.ch[1].dar0.dar0 == 0x48400000u);
    for (unsigned i = 0; i < 10; ++i) {
        DW_GDMA.ch[1].int_st0.val = CSI_DMA_DONE;
        nih_csi_stream_irq(0);
        assert(DW_GDMA.ch[1].dar0.dar0 == 0x48400000u);
    }
    assert(nih_csi_stream_state(2) == 10);
    assert(!nih_csi_stream_release(generation + 1));
    assert(nih_csi_stream_release(generation));
    assert(!nih_csi_stream_release(generation));
    DW_GDMA.ch[1].int_st0.val = CSI_DMA_DONE;
    nih_csi_stream_irq(0);
    assert(nih_csi_stream_borrow(&generation) == 0x48400000u && generation == 12);
    nih_csi_stream_stop();
    assert(nih_csi_stream_release(generation));
    DW_GDMA.ch[1].int_st0.val = CSI_DMA_DONE;
    nih_csi_stream_irq(0);
    assert(nih_csi_stream_state(4) && !enabled && !MIPI_CSI_BRIDGE.csi_en.csi_brg_en);
    assert(nih_csi_stream_end());
    assert(nih_csi_stream_begin(0x48200000u, 0x48400000u));
    rx = (csi_rx){0};
    assert(nih_csi_dma_arm(&rx) && nih_csi_dma_bridge_on(&rx));
    DW_GDMA.ch[1].int_st0.val = CSI_DMA_DONE;
    nih_csi_stream_irq(0);
    uint32_t next_generation = 0;
    assert(nih_csi_stream_borrow(&next_generation) == 0x48200000u);
    assert(next_generation > generation && !nih_csi_stream_release(generation));
    assert(nih_csi_stream_release(next_generation));
    nih_csi_stream_stop();
    DW_GDMA.ch[1].int_st0.val = CSI_DMA_DONE;
    nih_csi_stream_irq(0);
    HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_brg_sys_clk_en = 0;
    MIPI_CSI_BRIDGE.csi_en.csi_brg_en = 1; /* inaccessible clock-gated value */
    assert(nih_csi_stream_end());
    HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_brg_sys_clk_en = 1;
    MIPI_CSI_BRIDGE.csi_en.csi_brg_en = 0;
    assert(!nih_csi_stream_begin(0x48200000u, 0x48200000u));
    assert(!nih_csi_stream_begin(0x48200001u, 0x48400000u));
    assert(!nih_csi_stream_begin(0x48000000u, 0x48400000u));
    assert(!nih_csi_stream_begin(0x48200000u, 0x4c000000u));
    assert(nih_csi_stream_begin(0x48200000u, 0x48400000u));
    rx = (csi_rx){0};
    assert(nih_csi_dma_arm(&rx) && nih_csi_dma_bridge_on(&rx));
    DW_GDMA.ch[1].int_st0.val = CSI_DMA_DONE;
    nih_csi_stream_irq(0x400u); /* shared controller fault beats completed data */
    assert(nih_csi_stream_state(3) & 0x400u);
    assert(nih_csi_stream_state(4) && !enabled && !MIPI_CSI_BRIDGE.csi_en.csi_brg_en);
    assert(nih_csi_stream_borrow(&next_generation) == 0);
    assert(!nih_csi_stream_begin(0x48200000u, 0x48400000u));
    assert(nih_csi_stream_end()); /* isolated replay only; production stays pinned */
    for (unsigned scenario = 0; scenario < 4; ++scenario) {
        MIPI_CSI_BRIDGE.int_raw.val = 0;
        assert(nih_csi_stream_begin(0x48200000u, 0x48400000u));
        rx = (csi_rx){0};
        assert(nih_csi_dma_arm(&rx) && nih_csi_dma_bridge_on(&rx));
        for (unsigned i = 0; i < (scenario == 0 ? 4u : 1u); ++i) {
            MIPI_CSI_BRIDGE.int_raw.val = scenario == 1 ? 0xcu : 4u;
            DW_GDMA.ch[1].int_st0.val = scenario == 3 ? 0 : CSI_DMA_DONE | (scenario == 2 ? (1u << 5) : 0u);
            nih_csi_stream_irq(0);
        }
        assert(nih_csi_stream_state(3) && nih_csi_stream_state(4) && !enabled);
        assert(nih_csi_stream_borrow(&next_generation) == 0);
        assert(nih_csi_stream_end());
    }
    assert(DW_GDMA.ch[0].int_sig_ena0.val == 0x12345678);
    puts("CSI DMA one-frame control replay passed");
}
