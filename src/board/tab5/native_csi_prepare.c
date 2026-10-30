/* ESP32-P4 CSI receiver preflight for SC202CS 720p RAW8.
 * Register facts/sequencing: ESP-IDF v5.4.4 mipi_csi_hal.c and LL headers,
 * Apache-2.0. This file is not linked into the normal firmware.
 * CPU0 caller must serialize CSI/ISP ownership and RCC read-modify-writes,
 * and guarantee VDD_MIPI_DPHY remains supplied by the shared board owner.
 * This code never starts the sensor, bridge output, DMA, or ISP.
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "hal/mipi_csi_ll.h"
#include "soc/hp_sys_clkrst_struct.h"
#include "soc/pmu_struct.h"
#if defined(__riscv)
__asm__(".global MIPI_CSI_BRIDGE\n.set MIPI_CSI_BRIDGE,0x5009f800\n"
        ".global MIPI_CSI_HOST\n.set MIPI_CSI_HOST,0x5009f000\n");
#endif

static bool owned;
/* Read-only admission diagnostics. The caller serializes RCC access. */
uint32_t nih_csi_prepare_busy_flags(void) {
    return (HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_brg_sys_clk_en ? 1u : 0u) |
           (HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_host_sys_clk_en ? 2u : 0u) |
           (HP_SYS_CLKRST.peri_clk_ctrl03.reg_mipi_csi_dphy_cfg_clk_en ? 4u : 0u) |
           (owned ? 8u : 0u);
}
/* IDF's range table maps 550..599 Mbps to selection 0x07. */
static void phy_576mbps(csi_host_dev_t *host) {
    mipi_csi_phy_ll_write_clock(host, 0, false);
    mipi_csi_phy_ll_write_reg_addr(host, 0x44);
    mipi_csi_phy_ll_write_clock(host, 1, false);
    mipi_csi_phy_ll_write_clock(host, 0, false);
    mipi_csi_phy_ll_write_reg_val(host, 0x0e);
    mipi_csi_phy_ll_write_clock(host, 1, false);
    mipi_csi_phy_ll_write_clock(host, 0, false);
}

/* -1: already owned, -2: pre-existing shared block, -3: readback failed,
 * -4: the shared MIPI regulator is not enabled (not electrical measurement).
 * On -3 the caller must invoke stop and examine its result before reuse. */
int32_t nih_csi_prepare_720p(void) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    if (owned) return -1;
    if (!PMU.ext_ldo[1].pmu_ext_ldo.xpd) return -4;
    if (HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_brg_sys_clk_en ||
        HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_host_sys_clk_en ||
        HP_SYS_CLKRST.peri_clk_ctrl03.reg_mipi_csi_dphy_cfg_clk_en) return -2;
    owned = true; /* Set before first change, including a partial failure. */
    mipi_csi_ll_enable_brg_module_clock(0, true);
    mipi_csi_ll_reset_brg_module_clock(0);
    mipi_csi_brg_ll_enable_clock(&MIPI_CSI_BRIDGE, true);
    mipi_csi_ll_enable_host_bus_clock(0, true);
    mipi_csi_ll_reset_host_clock(0);
    mipi_csi_ll_set_phy_clock_source(0, MIPI_CSI_PHY_CLK_SRC_PLL_F20M);
    mipi_csi_ll_enable_phy_config_clock(0, true);
    mipi_csi_phy_ll_enable_shutdown_input(&MIPI_CSI_HOST, true);
    mipi_csi_phy_ll_enable_reset_output(&MIPI_CSI_HOST, true);
    mipi_csi_host_ll_enable_reset_output(&MIPI_CSI_HOST, true);
    mipi_csi_phy_ll_write_reg_addr(&MIPI_CSI_HOST, 0);
    mipi_csi_phy_ll_write_clock(&MIPI_CSI_HOST, 0, true);
    mipi_csi_phy_ll_write_clock(&MIPI_CSI_HOST, 0, false);
    phy_576mbps(&MIPI_CSI_HOST);
    mipi_csi_phy_ll_enable_shutdown_input(&MIPI_CSI_HOST, false);
    mipi_csi_phy_ll_enable_reset_output(&MIPI_CSI_HOST, false);
    mipi_csi_host_ll_enable_reset_output(&MIPI_CSI_HOST, false);
    mipi_csi_host_ll_set_active_lanes_num(&MIPI_CSI_HOST, 1);
    mipi_csi_host_ll_enable_virtual_channel_extension(&MIPI_CSI_HOST, false);
    mipi_csi_host_ll_enable_scrambling(&MIPI_CSI_HOST, false);
    mipi_csi_brg_ll_enable(&MIPI_CSI_BRIDGE, false);
    mipi_csi_brg_ll_set_intput_data_h_pixel_num(&MIPI_CSI_BRIDGE, 1280);
    mipi_csi_brg_ll_set_intput_data_v_row_num(&MIPI_CSI_BRIDGE, 720);
    mipi_csi_brg_ll_set_flow_ctl_buf_afull_thrd(&MIPI_CSI_BRIDGE, 960);
    mipi_csi_brg_ll_set_data_type_min(&MIPI_CSI_BRIDGE, 0x12);
    mipi_csi_brg_ll_set_data_type_max(&MIPI_CSI_BRIDGE, 0x2f);
    mipi_csi_brg_ll_set_byte_endian(&MIPI_CSI_BRIDGE, false);
    mipi_csi_brg_ll_set_burst_len(&MIPI_CSI_BRIDGE, 512);
    if (!HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_brg_sys_clk_en ||
        !HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_host_sys_clk_en ||
        !HP_SYS_CLKRST.peri_clk_ctrl03.reg_mipi_csi_dphy_cfg_clk_en ||
        MIPI_CSI_BRIDGE.csi_en.csi_brg_en || MIPI_CSI_HOST.n_lanes.n_lanes != 0 ||
        MIPI_CSI_BRIDGE.frame_cfg.hadr_num != 1280 || MIPI_CSI_BRIDGE.frame_cfg.vadr_num != 720 ||
        MIPI_CSI_BRIDGE.data_type_cfg.data_type_min != 0x12 || MIPI_CSI_BRIDGE.data_type_cfg.data_type_max != 0x2f) return -3;
    return 0;
}

/* Preflight has never enabled bridge transfer or DMA. Do not call while a
 * future capture is active; capture's independent DMA/IRQ stop is mandatory. */
bool nih_csi_prepare_stop(void) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    if (!owned || MIPI_CSI_BRIDGE.csi_en.csi_brg_en) return false;
    mipi_csi_host_ll_enable_reset_output(&MIPI_CSI_HOST, true);
    mipi_csi_phy_ll_enable_reset_output(&MIPI_CSI_HOST, true);
    mipi_csi_phy_ll_enable_shutdown_input(&MIPI_CSI_HOST, true);
    mipi_csi_ll_enable_phy_config_clock(0, false);
    mipi_csi_ll_enable_host_bus_clock(0, false);
    mipi_csi_brg_ll_enable_clock(&MIPI_CSI_BRIDGE, false);
    mipi_csi_ll_enable_brg_module_clock(0, false);
    if (HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_brg_sys_clk_en ||
        HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_host_sys_clk_en ||
        HP_SYS_CLKRST.peri_clk_ctrl03.reg_mipi_csi_dphy_cfg_clk_en) return false;
    owned = false;
    return true;
}
