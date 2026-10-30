#ifdef NDEBUG
#error "Host replay requires active assertions"
#endif
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include "hal/isp_ll.h"
isp_dev_t ISP;
hp_sys_clkrst_dev_t HP_SYS_CLKRST;
#include "../../src/board/tab5/native_camera_isp.c"
int main(void) {
    HP_SYS_CLKRST.peri_clk_ctrl25.reg_isp_clk_en = 1;
    assert(nih_camera_isp_start() == -1);
    HP_SYS_CLKRST.peri_clk_ctrl25.reg_isp_clk_en = 0;
    HP_SYS_CLKRST.peri_clk_ctrl25.reg_isp_clk_src_sel = 2;
    HP_SYS_CLKRST.peri_clk_ctrl26.reg_isp_clk_div_num = 5;
    assert(nih_camera_isp_start() == 0);
    assert(nih_camera_isp_start() == -1);
    assert(ISP.cntl.isp_en && ISP.cntl.mipi_data_en && !ISP.cntl.demosaic_en);
    assert(ISP.frame_cfg.hadr_num == 1279 && ISP.frame_cfg.vadr_num == 719);
    assert(nih_camera_isp_stop());
    assert(!nih_camera_isp_stop());
    assert(!HP_SYS_CLKRST.peri_clk_ctrl25.reg_isp_clk_en);
    assert(HP_SYS_CLKRST.peri_clk_ctrl25.reg_isp_clk_src_sel == 2);
    assert(HP_SYS_CLKRST.peri_clk_ctrl26.reg_isp_clk_div_num == 5);
    puts("Camera RAW8 ISP register replay passed");
}
