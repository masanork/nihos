/* ESP32-P4 CSI one-frame DMA register configuration, not start/stop.
 * Register meanings and transfer geometry: ESP-IDF v5.4.4 DW-GDMA and CSI LL.
 * This isolated object is not linked into the normal image.
 * CPU0 caller must exclusively own channel 1, the CSI bridge and the provided
 * DMA-capable frame lease, and serialize shared RCC/IRQ/cache operations.
 * It neither performs cache handoff nor enables DMA, CSI or interrupts.
 */
#include <stdint.h>
#include <stdlib.h>
#include "hal/dw_gdma_ll.h"
#include "soc/reg_base.h"

#define CSI_CHANNEL 1u
#if NIH_NATIVE_CAMERA_JPEG
#define FRAME_BYTES (1280u * 720u * 2u)
#else
#define FRAME_BYTES (1280u * 720u)
#endif
#define CACHE_ALIGN 64u
_Static_assert(FRAME_BYTES % 64u == 0, "whole cache lines");

/* The external caller must prove lease ownership; these checks only validate
 * arithmetic. The display reservation and any other buffers must be excluded. */
int32_t nih_csi_dma_configure(uint32_t frame, uint32_t lease_start, uint32_t lease_size) {
    const uint64_t frame_end = (uint64_t)frame + FRAME_BYTES;
    const uint64_t lease_end = (uint64_t)lease_start + lease_size;
    if ((frame & (CACHE_ALIGN - 1u)) || frame_end > UINT32_MAX || lease_end > UINT32_MAX ||
        frame < lease_start || frame_end > lease_end) return -1;
    if (!(DW_GDMA.cfg0.dmac_en) || (DW_GDMA.chen0.val & (1u << CSI_CHANNEL))) return -2;
    /* No global disable, reset, interrupt clear or channel 0 modification. */
    dw_gdma_ll_channel_set_trans_flow(&DW_GDMA, CSI_CHANNEL, DW_GDMA_ROLE_PERIPH_CSI, DW_GDMA_ROLE_MEM, DW_GDMA_FLOW_CTRL_SRC);
    dw_gdma_ll_channel_set_src_multi_block_type(&DW_GDMA, CSI_CHANNEL, DW_GDMA_BLOCK_TRANSFER_CONTIGUOUS);
    dw_gdma_ll_channel_set_dst_multi_block_type(&DW_GDMA, CSI_CHANNEL, DW_GDMA_BLOCK_TRANSFER_CONTIGUOUS);
    dw_gdma_ll_channel_set_src_handshake_interface(&DW_GDMA, CSI_CHANNEL, DW_GDMA_HANDSHAKE_HW);
    dw_gdma_ll_channel_set_dst_handshake_interface(&DW_GDMA, CSI_CHANNEL, DW_GDMA_HANDSHAKE_HW);
    dw_gdma_ll_channel_set_src_handshake_periph(&DW_GDMA, CSI_CHANNEL, DW_GDMA_ROLE_PERIPH_CSI);
    dw_gdma_ll_channel_set_priority(&DW_GDMA, CSI_CHANNEL, 1);
    dw_gdma_ll_channel_set_src_outstanding_limit(&DW_GDMA, CSI_CHANNEL, 5);
    dw_gdma_ll_channel_set_dst_outstanding_limit(&DW_GDMA, CSI_CHANNEL, 5);
    dw_gdma_ll_channel_set_src_periph_status_addr(&DW_GDMA, CSI_CHANNEL, MIPI_CSI_BRG_MEM_BASE);
    dw_gdma_ll_channel_set_src_addr(&DW_GDMA, CSI_CHANNEL, MIPI_CSI_BRG_MEM_BASE);
    dw_gdma_ll_channel_set_dst_addr(&DW_GDMA, CSI_CHANNEL, frame);
    dw_gdma_ll_channel_set_trans_block_size(&DW_GDMA, CSI_CHANNEL, FRAME_BYTES / 8);
    dw_gdma_ll_channel_set_src_master_port(&DW_GDMA, CSI_CHANNEL, MIPI_CSI_BRG_MEM_BASE);
    dw_gdma_ll_channel_set_dst_master_port(&DW_GDMA, CSI_CHANNEL, frame);
    dw_gdma_ll_channel_set_src_trans_width(&DW_GDMA, CSI_CHANNEL, DW_GDMA_TRANS_WIDTH_64);
    dw_gdma_ll_channel_set_dst_trans_width(&DW_GDMA, CSI_CHANNEL, DW_GDMA_TRANS_WIDTH_64);
    dw_gdma_ll_channel_set_src_burst_mode(&DW_GDMA, CSI_CHANNEL, DW_GDMA_BURST_MODE_FIXED);
    dw_gdma_ll_channel_set_dst_burst_mode(&DW_GDMA, CSI_CHANNEL, DW_GDMA_BURST_MODE_INCREMENT);
    dw_gdma_ll_channel_set_src_burst_items(&DW_GDMA, CSI_CHANNEL, DW_GDMA_BURST_ITEMS_512);
    dw_gdma_ll_channel_set_dst_burst_items(&DW_GDMA, CSI_CHANNEL, DW_GDMA_BURST_ITEMS_512);
    dw_gdma_ll_channel_set_src_burst_len(&DW_GDMA, CSI_CHANNEL, 16);
    dw_gdma_ll_channel_set_dst_burst_len(&DW_GDMA, CSI_CHANNEL, 16);
    dw_gdma_ll_channel_enable_src_periph_status_write_back(&DW_GDMA, CSI_CHANNEL, false);
    dw_gdma_ll_channel_enable_dst_periph_status_write_back(&DW_GDMA, CSI_CHANNEL, false);
    if (DW_GDMA.ch[CSI_CHANNEL].sar0.sar0 != MIPI_CSI_BRG_MEM_BASE ||
        DW_GDMA.ch[CSI_CHANNEL].dar0.dar0 != frame ||
        DW_GDMA.ch[CSI_CHANNEL].block_ts0.block_ts != FRAME_BYTES / 8 - 1) return -3;
    return 0;
}
