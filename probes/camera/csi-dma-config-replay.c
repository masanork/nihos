/* Host replay of actual DW-GDMA LL register configuration, without DMA. */
#ifdef NDEBUG
#error "Host replay requires active assertions"
#endif
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "hal/dw_gdma_ll.h"
dw_gdma_dev_t DW_GDMA;
hp_sys_clkrst_dev_t HP_SYS_CLKRST;
#include "../../src/board/tab5/native_csi_dma_config.c"
int main(void) {
    assert(nih_csi_dma_configure(0x48200000u, 0x48200000u, FRAME_BYTES) == -2);
    DW_GDMA.cfg0.dmac_en = 1;
    DW_GDMA.chen0.val = 2;
    assert(nih_csi_dma_configure(0x48200000u, 0x48200000u, FRAME_BYTES) == -2);
    DW_GDMA.chen0.val = 1; /* display running, camera channel disabled */
    DW_GDMA.ch[0].sar0.sar0 = 0x12345678;
    DW_GDMA.ch[0].dar0.dar0 = 0x87654321;
    DW_GDMA.ch[0].cfg1.val = 0x13579bdf;
    assert(nih_csi_dma_configure(0x48200001u, 0x48200000u, FRAME_BYTES + 64) == -1);
    assert(nih_csi_dma_configure(0x48200000u, 0x48200000u, FRAME_BYTES - 64) == -1);
    assert(nih_csi_dma_configure(0xffff0000u, 0xffff0000u, FRAME_BYTES) == -1);
    assert(nih_csi_dma_configure(0x48200000u, 0x48200000u, FRAME_BYTES) == 0);
    assert(DW_GDMA.ch[1].sar0.sar0 == MIPI_CSI_BRG_MEM_BASE);
    assert(DW_GDMA.ch[1].dar0.dar0 == 0x48200000u);
    assert(DW_GDMA.ch[1].block_ts0.block_ts == FRAME_BYTES / 8 - 1);
    assert(DW_GDMA.ch[1].cfg1.tt_fc == DW_GDMA_LL_FLOW_P2M_SRC);
    assert(DW_GDMA.ch[1].cfg1.src_per == DW_GDMA_LL_HW_HANDSHAKE_PERIPH_CSI);
    assert(DW_GDMA.ch[1].ctl0.sms == DW_GDMA_LL_MASTER_PORT_MIPI_CSI);
    assert(DW_GDMA.ch[1].ctl0.dms == DW_GDMA_LL_MASTER_PORT_MEMORY);
    assert(DW_GDMA.ch[1].ctl0.src_tr_width == DW_GDMA_TRANS_WIDTH_64);
    assert(DW_GDMA.ch[1].ctl0.dst_tr_width == DW_GDMA_TRANS_WIDTH_64);
    assert(DW_GDMA.ch[0].sar0.sar0 == 0x12345678);
    assert(DW_GDMA.ch[0].dar0.dar0 == 0x87654321);
    assert(DW_GDMA.ch[0].cfg1.val == 0x13579bdf);
    assert(DW_GDMA.chen0.val == 1 && DW_GDMA.cfg0.dmac_en);
    puts("CSI DMA configuration replay passed");
}
