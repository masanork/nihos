#ifdef NDEBUG
#error "Host replay requires active assertions"
#endif
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include "hal/ledc_ll.h"
#include "hal/gpio_ll.h"
ledc_dev_t LEDC;
ledc_gamma_ram_t LEDC_GAMMA_RAM;
gpio_dev_t GPIO;
io_mux_dev_t IO_MUX;
hp_sys_clkrst_dev_t HP_SYS_CLKRST;
#include "../../src/board/tab5/native_camera_xclk.c"
int main(void) {
    HP_SYS_CLKRST.soc_clk_ctrl3.reg_ledc_apb_clk_en = 1;
    assert(!nih_camera_xclk_start());
    HP_SYS_CLKRST.soc_clk_ctrl3.reg_ledc_apb_clk_en = 0;
    GPIO.enable1.val = 1u << 4;
    assert(!nih_camera_xclk_start());
    GPIO.enable1.val = 0;
    IO_MUX.gpio[36].val = 0x123;
    GPIO.func_out_sel_cfg[36].val = 0x234;
    GPIO.pin[36].val = 0x345;
    assert(nih_camera_xclk_start());
    assert(!nih_camera_xclk_start());
    assert(LEDC.timer_group[LEDC_LOW_SPEED_MODE].timer[0].conf.clk_div == 427);
    assert(LEDC.timer_group[LEDC_LOW_SPEED_MODE].timer[0].conf.duty_res == 1);
    assert(GPIO.func_out_sel_cfg[36].out_sel == LEDC_LS_SIG_OUT_PAD_OUT0_IDX);
    GPIO.in1.in1_data_next = 0;
    assert(nih_camera_xclk_levels() == 1);
    GPIO.in1.in1_data_next = 1u << 4;
    assert(nih_camera_xclk_levels() == 2);
    assert(nih_camera_xclk_stop());
    assert(nih_camera_xclk_levels() == 0);
    assert(!nih_camera_xclk_stop());
    assert(IO_MUX.gpio[36].val == 0x123 && GPIO.func_out_sel_cfg[36].val == 0x234 && GPIO.pin[36].val == 0x345);
    assert(!HP_SYS_CLKRST.soc_clk_ctrl3.reg_ledc_apb_clk_en);
    puts("Camera XCLK register replay passed");
}
