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

/* Boot-exclusive power enable. Preserve all other expander/charger outputs.
 * PI4IOE5V6408: 0x03 direction (1=output), 0x05 output, 0x07 output high-Z.
 * Only expander 0x44 P0 (WLAN_PWR_EN) is modified; no chip reset is issued. */
extern void nih_c6_delay_us(unsigned);
static void i2c_delay(void) { nih_c6_delay_us(5); }
static void i2c_sda(unsigned high) { gpio_ll_set_level(&GPIO, 31, high); i2c_delay(); }
static int i2c_scl(unsigned high) {
    gpio_ll_set_level(&GPIO, 32, high);
    if (high) {
        unsigned tries = 100;
        while (!gpio_ll_get_level(&GPIO, 32) && --tries) i2c_delay();
        if (!tries) return 0;
    }
    i2c_delay(); return 1;
}
static int i2c_start(void) {
    i2c_sda(1); if (!i2c_scl(1) || !gpio_ll_get_level(&GPIO, 31)) return 0;
    i2c_sda(0); return i2c_scl(0);
}
static void i2c_stop(void) { i2c_sda(0); (void)i2c_scl(1); i2c_sda(1); }
static int i2c_put(unsigned byte) {
    for (int bit = 7; bit >= 0; --bit) {
        i2c_sda((byte >> bit) & 1); if (!i2c_scl(1)) return 0; (void)i2c_scl(0);
    }
    i2c_sda(1); if (!i2c_scl(1)) return 0;
    int ack = !gpio_ll_get_level(&GPIO, 31); (void)i2c_scl(0); return ack;
}
static int i2c_get(unsigned *value) {
    *value = 0; i2c_sda(1);
    for (int bit = 7; bit >= 0; --bit) {
        if (!i2c_scl(1)) return 0;
        *value |= gpio_ll_get_level(&GPIO, 31) << bit; (void)i2c_scl(0);
    }
    if (!i2c_scl(1)) return 0; (void)i2c_scl(0); return 1; /* NACK */
}
static int exp_read(unsigned reg, unsigned *value) {
    int ok = i2c_start() && i2c_put(0x88) && i2c_put(reg) &&
             i2c_start() && i2c_put(0x89) && i2c_get(value);
    i2c_stop(); return ok;
}
static int exp_write(unsigned reg, unsigned value) {
    int ok = i2c_start() && i2c_put(0x88) && i2c_put(reg) && i2c_put(value);
    i2c_stop(); return ok;
}
unsigned nih_c6_power_enable(void) {
    for (unsigned pin = 31; pin <= 32; ++pin) {
        IO_MUX.gpio[pin].mcu_sel = 1;
        GPIO.func_out_sel_cfg[pin].out_sel = SIG_GPIO_OUT_IDX;
        GPIO.func_out_sel_cfg[pin].oen_sel = 1;
        gpio_ll_input_enable(&GPIO, pin); gpio_ll_pullup_en(&GPIO, pin);
        gpio_ll_pulldown_dis(&GPIO, pin); gpio_ll_od_enable(&GPIO, pin);
        gpio_ll_set_level(&GPIO, pin, 1); gpio_ll_output_enable(&GPIO, pin);
    }
    unsigned out = 0, dir = 0, hiz = 0, check = 0;
    int ok = exp_read(5, &out) && exp_read(3, &dir) && exp_read(7, &hiz) &&
             exp_write(5, out | 1) && exp_write(7, hiz & ~1u) && exp_write(3, dir | 1) &&
             exp_read(5, &check) && check == (out | 1) &&
             exp_read(7, &check) && check == (hiz & ~1u) &&
             exp_read(3, &check) && check == (dir | 1);
    /* Hand back the shared bus to the Zig master: its open-drain primitive
     * toggles output-enable around a LOW latch. Retaining this shim's HIGH
     * latch makes every subsequent RTC/sensor transfer unable to drive low. */
    for (unsigned pin = 31; pin <= 32; ++pin) {
        gpio_ll_output_disable(&GPIO, pin);
        gpio_ll_set_level(&GPIO, pin, 0);
        gpio_ll_od_disable(&GPIO, pin);
    }
    return ok;
}
