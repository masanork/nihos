/* Native boot-only Tab5 slot-0 pad/power/clock shim. No IDF runtime calls.
 * Register layouts: ESP-IDF v5.4.4 (Apache-2.0); Tab5 wiring: BSP 1.3.2.
 * This translation unit uses vendor LL definitions, not a linked SDK driver. */
#include <stddef.h>
#include "hal/gpio_ll.h"
#include "hal/sdmmc_ll.h"
#include "hal/timer_ll.h"
#include "hal/usb_serial_jtag_ll.h"
#include "soc/gpio_sig_map.h"

__asm__(".global GPIO\n.set GPIO,0x500e0000\n"
        ".global IO_MUX\n.set IO_MUX,0x500e1000\n"
        ".global PMU\n.set PMU,0x50115000\n"
        ".global HP_SYS_CLKRST\n.set HP_SYS_CLKRST,0x500e6000\n"
        ".global LP_AON_CLKRST\n.set LP_AON_CLKRST,0x50111000\n"
        ".global SDMMC\n.set SDMMC,0x50083000\n");
__asm__(".global TIMERG1\n.set TIMERG1,0x500c3000\n");
__asm__(".global USB_SERIAL_JTAG\n.set USB_SERIAL_JTAG,0x500d2000\n");

/* Boot capture only; no IRQ registration and no modem-line manipulation. */
int nih_boot_capture_getc(void) {
    uint8_t byte;
    return usb_serial_jtag_ll_read_rxfifo(&byte, 1) == 1 ? (int)byte : -1;
}

/* Sole TG1 owner, boot only. TG0 belongs to the two schedulers. */
unsigned nih_storage_clock_start(void) {
    int __DECLARE_RCC_RC_ATOMIC_ENV;
    int __DECLARE_RCC_ATOMIC_ENV;
    timer_ll_enable_bus_clock(1, true);
    timer_ll_reset_register(1);
    TIMERG1.wdtwprotect.wdt_wkey = 0x50d83aa1;
    TIMERG1.wdtconfig0.val = 0;
    TIMERG1.wdtwprotect.wdt_wkey = 0;
    timer_ll_set_clock_source(&TIMERG1, 0, GPTIMER_CLK_SRC_XTAL);
    timer_ll_enable_clock(&TIMERG1, 0, true);
    timer_ll_enable_intr(&TIMERG1, 3, false);
    timer_ll_set_clock_prescale(&TIMERG1, 0, 40);
    timer_ll_enable_auto_reload(&TIMERG1, 0, false);
    timer_ll_set_count_direction(&TIMERG1, 0, GPTIMER_COUNT_UP);
    timer_ll_set_reload_value(&TIMERG1, 0, 0);
    timer_ll_trigger_soft_reload(&TIMERG1, 0);
    timer_ll_enable_alarm(&TIMERG1, 0, false);
    timer_ll_enable_counter(&TIMERG1, 0, true);
    return HP_SYS_CLKRST.peri_clk_ctrl21.reg_timergrp1_t0_src_sel == 0 &&
           HP_SYS_CLKRST.peri_clk_ctrl21.reg_timergrp1_t0_clk_en == 1 &&
           (TIMERG1.int_ena_timers.val & 1u) == 0;

}

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
