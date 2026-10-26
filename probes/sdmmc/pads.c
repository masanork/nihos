/* Native boot-only Tab5 slot-0 pad/power/clock shim. No IDF runtime calls.
 * Register layouts: ESP-IDF v5.4.4 (Apache-2.0); Tab5 wiring: BSP 1.3.2.
 * This translation unit uses vendor LL definitions, not a linked SDK driver. */
#include <stddef.h>
#include "hal/gpio_ll.h"
#include "hal/sdmmc_ll.h"
#include "soc/gpio_sig_map.h"

__asm__(".global GPIO\n.set GPIO,0x500e0000\n"
        ".global IO_MUX\n.set IO_MUX,0x500e1000\n"
        ".global PMU\n.set PMU,0x50115000\n"
        ".global HP_SYS_CLKRST\n.set HP_SYS_CLKRST,0x500e6000\n"
        ".global LP_AON_CLKRST\n.set LP_AON_CLKRST,0x50111000\n"
        ".global SDMMC\n.set SDMMC,0x50083000\n");

void nih_sdmmc_power_off(void) {
    for (unsigned pin = 39; pin <= 44; ++pin) {
        IO_MUX.gpio[pin].mcu_sel = 1;
        gpio_ll_output_disable(&GPIO, pin);
        gpio_ll_pullup_dis(&GPIO, pin);
        gpio_ll_pulldown_dis(&GPIO, pin);
    }
    PMU.ext_ldo[4].pmu_ext_ldo.force_tieh_sel = 1;
    PMU.ext_ldo[4].pmu_ext_ldo.tieh_sel = 0;
    PMU.ext_ldo[4].pmu_ext_ldo.xpd = 0;
}

void nih_sdmmc_power_on(void) {
    /* D3 must be high during CMD0, or the card can latch SPI mode. */
    GPIO.func_out_sel_cfg[42].out_sel = SIG_GPIO_OUT_IDX;
    GPIO.func_out_sel_cfg[42].oen_sel = 1;
    gpio_ll_set_level(&GPIO, 42, 1);
    gpio_ll_output_enable(&GPIO, 42);
    for (unsigned pin = 39; pin <= 44; ++pin) {
        IO_MUX.gpio[pin].mcu_sel = pin == 42 ? 1 : 0;
        gpio_ll_input_enable(&GPIO, pin);
        gpio_ll_set_drive_capability(&GPIO, pin, 3);
        gpio_ll_pulldown_dis(&GPIO, pin);
        if (pin != 43) gpio_ll_pullup_en(&GPIO, pin);
    }
    /* VO4/SD only: 3.3 V rail bypass, so analog DREF/MUL are ignored. */
    PMU.ext_ldo[4].pmu_ext_ldo.tieh = 1;
    PMU.ext_ldo[4].pmu_ext_ldo_ana.en_vdet = 1;
    PMU.ext_ldo[4].pmu_ext_ldo.xpd = 1;
}

void nih_sdmmc_clock_init(void) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    sdmmc_ll_enable_bus_clock(&SDMMC, true);
    sdmmc_ll_reset_register(&SDMMC);
    /* Stock loader supplies PLL160M; divide to a 40 MHz host clock. */
    sdmmc_ll_set_clock_div(&SDMMC, 4);
    sdmmc_ll_select_clk_source(&SDMMC, SDMMC_CLK_SRC_PLL160M);
    sdmmc_ll_init_phase_delay(&SDMMC);
}

void nih_sdmmc_fourbit_pins(void) {
    /* Card has acknowledged ACMD6; return D3 from GPIO-high to slot-0 IOMUX. */
    IO_MUX.gpio[42].mcu_sel = 0;
}
