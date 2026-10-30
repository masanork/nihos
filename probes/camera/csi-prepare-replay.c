/* Host replay uses the actual ESP-IDF LL register structs and CSI preflight.
 * It does not emulate PHY signaling or volatile hardware timing. */
#ifdef NDEBUG
#error "Host replay requires active assertions"
#endif
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include "hal/mipi_csi_ll.h"
#include "soc/hp_sys_clkrst_struct.h"
#include "soc/pmu_struct.h"
hp_sys_clkrst_dev_t HP_SYS_CLKRST;
pmu_dev_t PMU;
csi_host_dev_t MIPI_CSI_HOST;
csi_brg_dev_t MIPI_CSI_BRIDGE;
#include "../../src/board/tab5/native_csi_prepare.c"
int main(void) {
    assert(nih_csi_prepare_720p() == -4);
    PMU.ext_ldo[1].pmu_ext_ldo.xpd = 1;
    HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_host_sys_clk_en = 1;
    assert(nih_csi_prepare_720p() == -2);
    assert(!nih_csi_prepare_stop());
    HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_host_sys_clk_en = 0;
    /* An unrelated DSI clock is retained across the CSI lifecycle. */
    uint32_t unrelated = 1u << 2;
    HP_SYS_CLKRST.soc_clk_ctrl1.val |= unrelated;
    assert(nih_csi_prepare_720p() == 0);
    assert(nih_csi_prepare_720p() == -1);
    assert(MIPI_CSI_BRIDGE.csi_en.csi_brg_en == 0);
    assert(MIPI_CSI_BRIDGE.frame_cfg.hadr_num == 1280);
    assert(MIPI_CSI_BRIDGE.frame_cfg.vadr_num == 720);
    MIPI_CSI_BRIDGE.csi_en.csi_brg_en = 1;
    assert(!nih_csi_prepare_stop());
    assert(HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_host_sys_clk_en);
    MIPI_CSI_BRIDGE.csi_en.csi_brg_en = 0;
    assert(nih_csi_prepare_stop());
    assert(!nih_csi_prepare_stop());
    assert(HP_SYS_CLKRST.soc_clk_ctrl1.val & unrelated);
    puts("CSI preflight replay passed");
}
