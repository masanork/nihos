/* CSI-to-RAW8 ISP diagnostic. Register operations follow ESP-IDF v5.4.4
 * isp_core/isp_ll (Apache-2.0). CPU0 holds CSI/ISP ownership and serializes
 * RCC changes with interrupts masked. This is not an image-quality pipeline. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include "hal/isp_ll.h"
#if defined(__riscv)
__asm__(".global ISP\n.set ISP,0x500a1000\n");
#endif
static bool owned;
static uint32_t saved_source, saved_div;
/* Return -1 for an existing owner; -2 means partially configured and stop is
 * required. No global DMA or CSI reset/interrupt clear is performed. */
int32_t nih_camera_isp_start(void) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    if (owned || HP_SYS_CLKRST.peri_clk_ctrl25.reg_isp_clk_en) return -1;
    saved_source = HP_SYS_CLKRST.peri_clk_ctrl25.reg_isp_clk_src_sel;
    saved_div = HP_SYS_CLKRST.peri_clk_ctrl26.reg_isp_clk_div_num;
    owned = true;
    isp_ll_enable_module_clock(&ISP, true);
    isp_ll_reset_module_clock(&ISP);
    isp_ll_init(&ISP);
    isp_ll_select_clk_source(&ISP, ISP_CLK_SRC_PLL160);
    const hal_utils_clk_div_t div = { .integer = 1 };
    isp_ll_set_clock_div(&ISP, &div);
    const color_space_pixel_format_t raw = { .color_type_id = ISP_COLOR_RAW8 };
    if (!isp_ll_set_input_data_color_format(&ISP, raw) || !isp_ll_set_output_data_color_format(&ISP, raw)) return -2;
    isp_ll_clk_enable(&ISP, true);
    isp_ll_set_input_data_source(&ISP, ISP_INPUT_DATA_SOURCE_CSI);
    isp_ll_enable_line_start_packet_exist(&ISP, false);
    isp_ll_enable_line_end_packet_exist(&ISP, false);
    isp_ll_set_intput_data_h_pixel_num(&ISP, 1280);
    isp_ll_set_intput_data_v_row_num(&ISP, 720);
    isp_ll_set_bayer_mode(&ISP, COLOR_RAW_ELEMENT_ORDER_BGGR);
    isp_ll_shadow_set_mode(&ISP, ISP_SHADOW_MODE_UPDATE_ONLY_NEXT_VSYNC);
    isp_ll_enable(&ISP, true);
    if (!HP_SYS_CLKRST.peri_clk_ctrl25.reg_isp_clk_en || !ISP.clk_en.clk_en ||
        !ISP.cntl.isp_en || !ISP.cntl.mipi_data_en || ISP.cntl.isp_in_src != 0 ||
        ISP.cntl.isp_data_type != 0 || ISP.cntl.isp_out_type != 0 ||
        ISP.frame_cfg.hadr_num != 1279 || ISP.frame_cfg.vadr_num != 719) return -2;
    return 0;
}
/* Caller first stops sensor and proves the DMA channel disabled. On uncertain
 * DMA/CSI stop the caller must retain ISP ownership instead of calling here. */
bool nih_camera_isp_stop(void) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    if (!owned) return false;
    isp_ll_enable(&ISP, false);
    isp_ll_clk_enable(&ISP, false);
    isp_ll_enable_module_clock(&ISP, false);
    HP_SYS_CLKRST.peri_clk_ctrl25.reg_isp_clk_src_sel = saved_source;
    HP_SYS_CLKRST.peri_clk_ctrl26.reg_isp_clk_div_num = saved_div;
    if (HP_SYS_CLKRST.peri_clk_ctrl25.reg_isp_clk_en) return false;
    owned = false;
    return true;
}
