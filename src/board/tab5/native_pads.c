/* Native boot-only Tab5 display pad/PHY shim. No linked ESP-IDF driver.
 * Register layouts/sequences: ESP-IDF v5.4.4, Apache-2.0.
 * Wiring: official Tab5 NoGLIB BSP 1.3.2, Apache-2.0.
 * Display helpers leave SD pins, VO2/PSRAM and VO4/SD untouched.
 * The separate opt-in PSRAM helpers run exclusively before cache/SMP setup. */
#include <stddef.h>
#include "hal/gpio_ll.h"
#include "hal/usb_serial_jtag_ll.h"
#define efuse_hal_blk_version nih_display_efuse_block_version
#include "hal/ldo_ll.h"
#undef efuse_hal_blk_version
#include "hal/mipi_dsi_ll.h"
#include "soc/gpio_sig_map.h"
#include "soc/i2c_ana_mst_reg.h"
#include "soc/lp_clkrst_reg.h"
#include "soc/hp_sys_clkrst_reg.h"
#include "soc/lpperi_struct.h"
#include "soc/regi2c_cpll.h"
#include "soc/efuse_reg.h"
_Static_assert(EFUSE_RD_MAC_SYS_2_REG == 0x5012d04c, "native CPU revision guard");
_Static_assert(HP_SYS_CLKRST_ROOT_CLK_CTRL0_REG == 0x500e6004, "native CPU divider");
_Static_assert(HP_SYS_CLKRST_REG_CPU_CLK_DIV_NUM_S == 5, "native CPU divider shift");
_Static_assert(HP_SYS_CLKRST_REG_SOC_CLK_DIV_UPDATE == (1u << 4), "native clock handshake");
_Static_assert(LP_CLKRST_HP_ROOT_CLK_SRC_SEL_M == 3, "native CPU clock mux");
_Static_assert(I2C_CPLL == 0x67 && I2C_CPLL_OC_DIV_7_0 == 3 && I2C_CPLL_OC_REF_DIV == 2, "native CPLL readback");
_Static_assert(DR_REG_USB_SERIAL_JTAG_BASE == 0x500d2000, "diagnostic serial register base");
_Static_assert(DR_REG_TIMERGROUP1_BASE == 0x500c3000, "diagnostic timer group");
_Static_assert(HP_SYS_CLKRST_PERI_CLK_CTRL21_REG == 0x500e6098, "diagnostic clock source");
_Static_assert(HP_SYS_CLKRST_REG_TIMERGRP1_T0_SRC_SEL_S == 20, "diagnostic clock selector");
_Static_assert(PMU_RF_PWC_REG == 0x5011515c, "MPLL power register");
_Static_assert(PMU_MSPI_PHY_XPD == (1u << 24), "MPLL power bit");
_Static_assert(LP_CLKRST_HP_CLK_CTRL_REG == 0x50111040, "MPLL clock register");
_Static_assert(HP_SYS_CLKRST_ANA_PLL_CTRL0_REG == 0x500e60bc, "MPLL calibration register");
_Static_assert(I2C_ANA_MST_I2C0_CTRL_REG == 0x50124000, "MPLL analog bus register");

#if !NIH_NATIVE_SDMMC_PADS
__asm__(".global GPIO\n.set GPIO,0x500e0000\n"
        ".global IO_MUX\n.set IO_MUX,0x500e1000\n"
        ".global PMU\n.set PMU,0x50115000\n"
        ".global HP_SYS_CLKRST\n.set HP_SYS_CLKRST,0x500e6000\n");
#endif
__asm__(".global EFUSE\n.set EFUSE,0x5012d000\n"
        ".global MIPI_DSI_HOST\n.set MIPI_DSI_HOST,0x500a0000\n"
        ".global MIPI_DSI_BRIDGE\n.set MIPI_DSI_BRIDGE,0x500a0800\n");

uint32_t nih_display_efuse_block_version(void) {
    return EFUSE.rd_mac_sys_2.blk_version_major * 100 + EFUSE.rd_mac_sys_2.blk_version_minor;
}

void nih_display_pads_init(void) {
    /* Dark until real scanout has been proved; no software can enable it here. */
    IO_MUX.gpio[22].mcu_sel = 1;
    GPIO.func_out_sel_cfg[22].out_sel = SIG_GPIO_OUT_IDX;
    GPIO.func_out_sel_cfg[22].oen_sel = 1;
    GPIO.func_out_sel_cfg[22].out_inv_sel = 0;
    GPIO.func_out_sel_cfg[22].oen_inv_sel = 0;
    gpio_ll_set_level(&GPIO, 22, 0);
    gpio_ll_od_disable(&GPIO, 22);
    gpio_ll_input_enable(&GPIO, 22);
    gpio_ll_output_enable(&GPIO, 22);
    for (unsigned pin = 31; pin <= 32; ++pin) {
        // Release first: a retained output must not pulse SDA low while
        // changing the mux and preparing the low latch for open drain.
        gpio_ll_output_disable(&GPIO, pin);
        GPIO.func_out_sel_cfg[pin].out_sel = SIG_GPIO_OUT_IDX;
        GPIO.func_out_sel_cfg[pin].oen_sel = 1;
        GPIO.func_out_sel_cfg[pin].out_inv_sel = 0;
        GPIO.func_out_sel_cfg[pin].oen_inv_sel = 0;
        gpio_ll_set_level(&GPIO, pin, 0);
        gpio_ll_output_disable(&GPIO, pin);
        gpio_ll_input_enable(&GPIO, pin);
        gpio_ll_pullup_en(&GPIO, pin);
        gpio_ll_pulldown_dis(&GPIO, pin);
        IO_MUX.gpio[pin].mcu_sel = 1;
    }
}

void nih_keyboard_pads_init(void) {
    for (unsigned pin = 0; pin <= 1; ++pin) {
        gpio_ll_output_disable(&GPIO, pin);
        GPIO.func_out_sel_cfg[pin].out_sel = SIG_GPIO_OUT_IDX;
        GPIO.func_out_sel_cfg[pin].oen_sel = 1;
        GPIO.func_out_sel_cfg[pin].out_inv_sel = 0;
        GPIO.func_out_sel_cfg[pin].oen_inv_sel = 0;
        gpio_ll_set_level(&GPIO, pin, 0);
        gpio_ll_input_enable(&GPIO, pin);
        gpio_ll_pullup_en(&GPIO, pin);
        gpio_ll_pulldown_dis(&GPIO, pin);
        IO_MUX.gpio[pin].mcu_sel = 1;
    }
}
/* Existing ROM/loader USB Serial/JTAG configuration; no reset, TX or IRQ change. */
int32_t nih_diagnostic_serial_read(void) {
    uint8_t byte;
    return usb_serial_jtag_ll_read_rxfifo(&byte, 1) == 1 ? byte : -1;
}
static bool diagnostic_tx_stalled;
static uint32_t diagnostic_tx_dropped;
extern void nih_diagnostic_serial_idle(void);
void nih_diagnostic_serial_write(uint8_t byte) {
    if (diagnostic_tx_stalled && !usb_serial_jtag_ll_txfifo_writable()) {
        if (diagnostic_tx_dropped != UINT32_MAX) ++diagnostic_tx_dropped;
        return;
    }
    for (uint32_t spins = 0; !usb_serial_jtag_ll_txfifo_writable(); ++spins) {
        if ((spins & 255u) == 0) nih_diagnostic_serial_idle();
        if (spins == 199999u) {
            diagnostic_tx_stalled = true;
            if (diagnostic_tx_dropped != UINT32_MAX) ++diagnostic_tx_dropped;
            return;
        }
    }
    diagnostic_tx_stalled = false;
    usb_serial_jtag_ll_write_txfifo(&byte, 1);
    if (byte == '\n') usb_serial_jtag_ll_txfifo_flush();
}
uint32_t nih_diagnostic_serial_dropped(void) { return diagnostic_tx_dropped; }
__asm__(".global USB_SERIAL_JTAG\n.set USB_SERIAL_JTAG,0x500d2000\n");

void nih_display_pin_release(uint32_t pin, bool release) {
    if (pin != 0 && pin != 1 && pin != 31 && pin != 32) return;
    if (release) gpio_ll_output_disable(&GPIO, pin);
    else gpio_ll_output_enable(&GPIO, pin);
}
bool nih_display_pin_level(uint32_t pin) {
    return (pin == 0 || pin == 1 || pin == 31 || pin == 32) && gpio_ll_get_level(&GPIO, pin);
}

uint32_t nih_display_i2c_status(void) {
    return (gpio_ll_get_level(&GPIO, 31) ? 1u : 0u) |
           (gpio_ll_get_level(&GPIO, 32) ? 2u : 0u) |
           (((GPIO.enable.val >> 31) & 1u) << 8) |
           ((GPIO.enable1.val & 1u) << 9);
}

uint32_t nih_display_phy_power(void) {
    uint8_t dref, mul;
    bool rail;
    ldo_ll_voltage_to_dref_mul(2, 2500, &dref, &mul, &rail);
    ldo_ll_set_owner(2, LDO_LL_UNIT_OWNER_SW);
    ldo_ll_adjust_voltage(2, dref, mul, rail);
    PMU.ext_ldo[1].pmu_ext_ldo_ana.en_vdet = 1;
    PMU.ext_ldo[1].pmu_ext_ldo.xpd = 1;
    return (uint32_t)dref | ((uint32_t)mul << 8);
}

static void phy_write(uint8_t address, uint8_t value) {
    mipi_dsi_phy_ll_write_clock(&MIPI_DSI_HOST, 0, false);
    mipi_dsi_phy_ll_write_reg_addr(&MIPI_DSI_HOST, address);
    mipi_dsi_phy_ll_write_clock(&MIPI_DSI_HOST, 1, false);
    mipi_dsi_phy_ll_write_clock(&MIPI_DSI_HOST, 0, false);
    mipi_dsi_phy_ll_write_reg_val(&MIPI_DSI_HOST, value);
    mipi_dsi_phy_ll_write_clock(&MIPI_DSI_HOST, 1, false);
    mipi_dsi_phy_ll_write_clock(&MIPI_DSI_HOST, 0, false);
}

void nih_display_phy_init(uint32_t lane_mbps) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    mipi_dsi_ll_enable_bus_clock(0, true);
    mipi_dsi_ll_reset_register(0);
    mipi_dsi_ll_set_phy_config_clock_source(0, MIPI_DSI_PHY_CFG_CLK_SRC_PLL_F20M);
    mipi_dsi_ll_enable_phy_config_clock(0, true);
#if NIH_NATIVE_REV3
    mipi_dsi_ll_set_phy_pllref_clock_source(0, MIPI_DSI_PHY_PLLREF_CLK_SRC_XTAL);
#else
    mipi_dsi_ll_set_phy_pllref_clock_source(0, MIPI_DSI_PHY_PLLREF_CLK_SRC_PLL_F20M);
#endif
    mipi_dsi_ll_set_phy_pll_ref_clock_div(0, 1);
    mipi_dsi_ll_enable_phy_pllref_clock(0, true);
    mipi_dsi_phy_ll_set_data_lane_number(&MIPI_DSI_HOST, 2);
    mipi_dsi_host_ll_power_on_off(&MIPI_DSI_HOST, true);
    mipi_dsi_phy_ll_power_on_off(&MIPI_DSI_HOST, true);
    mipi_dsi_phy_ll_reset(&MIPI_DSI_HOST);
    mipi_dsi_phy_ll_enable_clock_lane(&MIPI_DSI_HOST, true);
    mipi_dsi_phy_ll_force_pll(&MIPI_DSI_HOST, true);
    mipi_dsi_brg_ll_reset(&MIPI_DSI_BRIDGE);
    /* M=50 for 1000 Mbit/s, M=48 for ST7121's achievable 960 Mbit/s.
     * N=1 at 20 MHz, or N=2 at 40 MHz XTAL. No parent PLL retuning. */
    const uint32_t multiplier = lane_mbps == 960 ? 48 : 50;
    phy_write(0x44, (lane_mbps == 960 ? 0x1a : 0x2a) << 1);
    phy_write(0x19, 0x30);
    phy_write(0x17, NIH_NATIVE_REV3 ? 1 : 0);
    phy_write(0x18, (multiplier - 1) & 0x1f);
    phy_write(0x18, 0x80 | ((multiplier - 1) >> 5));
    mipi_dsi_host_ll_enable_video_mode(&MIPI_DSI_HOST, false);
    mipi_dsi_host_ll_set_clock_lane_state(&MIPI_DSI_HOST, MIPI_DSI_LL_CLOCK_LANE_STATE_LP);
}

uint32_t nih_display_phy_status(void) {
    return (mipi_dsi_phy_ll_is_pll_locked(&MIPI_DSI_HOST) ? 1u : 0u) |
           (mipi_dsi_phy_ll_are_lanes_stopped(&MIPI_DSI_HOST, 2) ? 2u : 0u);
}

void nih_display_phy_power_off(void) {
    PMU.ext_ldo[1].pmu_ext_ldo.xpd = 0;
}

void nih_display_phy_stop(void) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    mipi_dsi_phy_ll_power_on_off(&MIPI_DSI_HOST, false);
    mipi_dsi_host_ll_power_on_off(&MIPI_DSI_HOST, false);
    mipi_dsi_ll_enable_phy_pllref_clock(0, false);
    mipi_dsi_ll_enable_phy_config_clock(0, false);
    mipi_dsi_ll_enable_bus_clock(0, false);
    nih_display_phy_power_off();
}

/* PSRAM200 bring-up helpers: caller owns both controllers before CPU1 release. */
#include "hal/psram_ctrlr_ll.h"
#include "hal/mspi_timing_tuning_ll.h"
__asm__(".global SPIMEM2\n.set SPIMEM2,0x5008e000\n"
        ".global SPIMEM3\n.set SPIMEM3,0x5008f000\n"
        ".global MSPI_IOMUX\n.set MSPI_IOMUX,0x500e1200\n");
void nih_psram_fast_clock(uint32_t divider) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    psram_ctrlr_ll_select_clk_source(2, PSRAM_CLK_SRC_MPLL);
    psram_ctrlr_ll_set_core_clock_div(2, 1);
    psram_ctrlr_ll_set_bus_clock(2, divider);
    psram_ctrlr_ll_set_bus_clock(3, divider);
}
void nih_psram_fast_phase(uint32_t phase) {
    mspi_timing_ll_set_dqs_phase(MSPI_LL_DQS_ID_0, phase);
    mspi_timing_ll_set_dqs_phase(MSPI_LL_DQS_ID_1, phase);
}
void nih_psram_fast_delay(uint32_t index) {
    const uint8_t dqs = index < 15 ? (uint8_t)(15 - index) : 0;
    const uint8_t data = index > 15 ? (uint8_t)(index - 15) : 0;
    for (uint32_t pin = 0; pin < MSPI_LL_PIN_MAX; ++pin)
        mspi_timing_ll_set_delayline(pin, pin == MSPI_LL_PIN_DQS0 || pin == MSPI_LL_PIN_DQS1 ? dqs : data);
}
void nih_psram_fast_setup(void) {
    psram_ctrlr_ll_enable_dll(2, true);
    psram_ctrlr_ll_enable_dll(3, true);
    psram_ctrlr_ll_enable_hex_data_line_mode(2, true);
    psram_ctrlr_ll_enable_variable_dummy(3, false);
}
