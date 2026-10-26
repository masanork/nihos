/* Tab5 C6 slot-1 boot-only pads/clock shim, using ESP-IDF v5.4.4 LL
 * definitions (Apache-2.0). No SDK runtime/driver, heap or FreeRTOS calls.
 * Resetting SDMMC requires exclusive ownership of BOTH slots. */
#include <stddef.h>
#include "hal/gpio_ll.h"
#include "soc/gpio_pins.h"
#include "hal/sdmmc_ll.h"
#include "soc/gpio_sig_map.h"

__asm__(".global GPIO\n.set GPIO,0x500e0000\n"
        ".global IO_MUX\n.set IO_MUX,0x500e1000\n"
        ".global HP_SYS_CLKRST\n.set HP_SYS_CLKRST,0x500e6000\n"
        ".global LP_AON_CLKRST\n.set LP_AON_CLKRST,0x50111000\n"
        ".global SDMMC\n.set SDMMC,0x50083000\n");

static void input_signal(unsigned signal, unsigned pin) {
    GPIO.func_in_sel_cfg[signal].in_sel = pin;
    GPIO.func_in_sel_cfg[signal].in_inv_sel = 0;
    GPIO.func_in_sel_cfg[signal].sig_in_sel = 1;
}

static void pin_signal(unsigned pin, unsigned signal, int input) {
    IO_MUX.gpio[pin].mcu_sel = 1;
    gpio_ll_pulldown_dis(&GPIO, pin);
    gpio_ll_set_drive_capability(&GPIO, pin, 3);
    if (input) {
        gpio_ll_input_enable(&GPIO, pin);
        gpio_ll_pullup_en(&GPIO, pin);
        input_signal(signal, pin);
    }
    GPIO.func_out_sel_cfg[pin].out_sel = signal;
    GPIO.func_out_sel_cfg[pin].out_inv_sel = 0;
    GPIO.func_out_sel_cfg[pin].oen_sel = 0;
    GPIO.func_out_sel_cfg[pin].oen_inv_sel = 0;
    gpio_ll_output_enable(&GPIO, pin);
}

void nih_c6_reset(unsigned release) {
    IO_MUX.gpio[15].mcu_sel = 1;
    GPIO.func_out_sel_cfg[15].out_sel = SIG_GPIO_OUT_IDX;
    GPIO.func_out_sel_cfg[15].oen_sel = 1;
    gpio_ll_set_level(&GPIO, 15, release != 0);
    gpio_ll_output_enable(&GPIO, 15);
}

void nih_c6_pads_init(void) {
    nih_c6_reset(0);
    pin_signal(12, SD_CARD_CCLK_2_PAD_OUT_IDX, 0);
    pin_signal(13, SD_CARD_CCMD_2_PAD_OUT_IDX, 1);
    pin_signal(11, SD_CARD_CDATA0_2_PAD_OUT_IDX, 1);
    /* Keep D3 high through CMD0; do not accidentally select SPI mode. */
    for (unsigned pin = 8; pin <= 10; ++pin) {
        IO_MUX.gpio[pin].mcu_sel = 1;
        gpio_ll_input_enable(&GPIO, pin);
        gpio_ll_pulldown_dis(&GPIO, pin);
        gpio_ll_pullup_en(&GPIO, pin);
        gpio_ll_output_disable(&GPIO, pin);
    }
    GPIO.func_out_sel_cfg[8].out_sel = SIG_GPIO_OUT_IDX;
    GPIO.func_out_sel_cfg[8].oen_sel = 1;
    gpio_ll_set_level(&GPIO, 8, 1);
    gpio_ll_output_enable(&GPIO, 8);
    input_signal(SD_CARD_DETECT_N_2_PAD_IN_IDX, GPIO_MATRIX_CONST_ZERO_INPUT);
    input_signal(SD_CARD_WRITE_PRT_2_PAD_IN_IDX, GPIO_MATRIX_CONST_ZERO_INPUT);
    input_signal(SD_CARD_INT_N_2_PAD_IN_IDX, GPIO_MATRIX_CONST_ONE_INPUT);
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    sdmmc_ll_enable_bus_clock(&SDMMC, true);
    sdmmc_ll_reset_register(&SDMMC);
    sdmmc_ll_set_clock_div(&SDMMC, 4);
    sdmmc_ll_select_clk_source(&SDMMC, SDMMC_CLK_SRC_PLL160M);
    sdmmc_ll_init_phase_delay(&SDMMC);
}

void nih_c6_fourbit_pins(void) {
    pin_signal(10, SD_CARD_CDATA1_2_PAD_OUT_IDX, 1);
    pin_signal(9, SD_CARD_CDATA2_2_PAD_OUT_IDX, 1);
    pin_signal(8, SD_CARD_CDATA3_2_PAD_OUT_IDX, 1);
}
