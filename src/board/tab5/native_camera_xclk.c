/* Tab5 sensor XCLK: GPIO36, LEDC channel/timer 0, PLL_F80M.
 * Register definitions and LEDC sequence: ESP-IDF v5.4.4 (Apache-2.0).
 * Wiring: Tab5 camera BSP and existing MeOS camera driver.
 * CPU0 must serialize RCC and GPIO36 ownership with interrupts masked.
 * Refuse an already-clocked LEDC or enabled GPIO36 rather than disturb it. */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include "hal/ledc_ll.h"
#include "hal/gpio_ll.h"
#include "soc/gpio_sig_map.h"
#if defined(__riscv)
__asm__(".global LEDC\n.set LEDC,0x500d3000\n.global LEDC_GAMMA_RAM\n.set LEDC_GAMMA_RAM,0x500d3400\n");
#endif
static bool owned;
static uint32_t old_mux, old_route, old_pin;
/* 80 MHz / (427/256) / 2 = 23.9812646 MHz, 0.078% below 24 MHz.
 * This is register-derived, not a measured waveform. */
#define XCLK_DIV 427u
bool nih_camera_xclk_start(void) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    if (owned || HP_SYS_CLKRST.soc_clk_ctrl3.reg_ledc_apb_clk_en ||
        (GPIO.enable1.val & (1u << 4))) return false;
    old_mux = IO_MUX.gpio[36].val;
    old_route = GPIO.func_out_sel_cfg[36].val;
    old_pin = GPIO.pin[36].val;
    owned = true;
    ledc_ll_enable_bus_clock(true);
    ledc_ll_enable_reset_reg(false);
    ledc_ll_set_slow_clk_sel(&LEDC, LEDC_SLOW_CLK_PLL_DIV);
    ledc_ll_enable_clock(&LEDC, true);
    ledc_ll_timer_pause(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_TIMER_0);
    ledc_ll_set_clock_divider(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_TIMER_0, XCLK_DIV);
    ledc_ll_set_duty_resolution(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_TIMER_0, 1);
    ledc_ll_timer_rst(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_TIMER_0);
    ledc_ll_ls_timer_update(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_TIMER_0);
    ledc_ll_bind_channel_timer(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, LEDC_TIMER_0);
    ledc_ll_set_hpoint(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, 0);
    ledc_ll_set_duty_int_part(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, 1);
    for (unsigned i = 0; i < SOC_LEDC_GAMMA_CURVE_FADE_RANGE_MAX; ++i)
        ledc_ll_set_fade_param_range(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, i, i == 0, i == 0, 0, i == 0);
    ledc_ll_set_range_number(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, 1);
    ledc_ll_set_sig_out_en(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, true);
    ledc_ll_set_duty_start(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
    ledc_ll_ls_channel_update(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
    ledc_ll_timer_resume(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_TIMER_0);
    ledc_ll_ls_timer_update(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_TIMER_0);
    gpio_ll_od_disable(&GPIO, 36);
    GPIO.func_out_sel_cfg[36].out_sel = LEDC_LS_SIG_OUT_PAD_OUT0_IDX;
    GPIO.func_out_sel_cfg[36].out_inv_sel = 0;
    GPIO.func_out_sel_cfg[36].oen_sel = 1;
    GPIO.func_out_sel_cfg[36].oen_inv_sel = 0;
    IO_MUX.gpio[36].mcu_sel = 1;
    gpio_ll_input_enable(&GPIO, 36); /* diagnostic sampling; previous mux restored on stop */
    gpio_ll_output_enable(&GPIO, 36);
    return HP_SYS_CLKRST.soc_clk_ctrl3.reg_ledc_apb_clk_en &&
        HP_SYS_CLKRST.peri_clk_ctrl22.reg_ledc_clk_en &&
        LEDC.timer_group[LEDC_LOW_SPEED_MODE].timer[0].conf.clk_div == XCLK_DIV &&
        LEDC.timer_group[LEDC_LOW_SPEED_MODE].timer[0].conf.duty_res == 1 &&
        GPIO.func_out_sel_cfg[36].out_sel == LEDC_LS_SIG_OUT_PAD_OUT0_IDX;
}
/* Bounded observation of logic levels only; does not measure frequency. */
uint32_t nih_camera_xclk_levels(void) {
    if (!owned) return 0;
    uint32_t levels = 0;
    for (unsigned i = 0; i < 128; ++i) levels |= gpio_ll_get_level(&GPIO, 36) ? 2u : 1u;
    return levels;
}
/* Even after failed start, call stop. Failure retains ownership until reboot. */
bool nih_camera_xclk_stop(void) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    if (!owned) return false;
    gpio_ll_output_disable(&GPIO, 36);
    ledc_ll_set_sig_out_en(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, false);
    ledc_ll_ls_channel_update(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0);
    ledc_ll_timer_pause(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_TIMER_0);
    ledc_ll_ls_timer_update(&LEDC, LEDC_LOW_SPEED_MODE, LEDC_TIMER_0);
    GPIO.func_out_sel_cfg[36].val = old_route;
    GPIO.pin[36].val = old_pin;
    IO_MUX.gpio[36].val = old_mux;
    ledc_ll_enable_clock(&LEDC, false);
    ledc_ll_enable_bus_clock(false);
    if (HP_SYS_CLKRST.soc_clk_ctrl3.reg_ledc_apb_clk_en || HP_SYS_CLKRST.peri_clk_ctrl22.reg_ledc_clk_en) return false;
    owned = false;
    return true;
}
