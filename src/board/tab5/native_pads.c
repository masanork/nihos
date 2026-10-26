/* Native boot-only Tab5 display pad/PHY shim. No linked ESP-IDF driver.
 * Register layouts/sequences: ESP-IDF v5.4.4, Apache-2.0.
 * Wiring: official Tab5 NoGLIB BSP 1.3.2, Apache-2.0.
 * No SD pins, VO2/PSRAM, VO4/SD, interrupt routing, or global PLL retuning. */
#include <stddef.h>
#include "hal/gpio_ll.h"
#define efuse_hal_blk_version nih_display_efuse_block_version
#include "hal/ldo_ll.h"
#undef efuse_hal_blk_version
#include "hal/mipi_dsi_ll.h"
#include "soc/gpio_sig_map.h"

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
        IO_MUX.gpio[pin].mcu_sel = 1;
        GPIO.func_out_sel_cfg[pin].out_sel = SIG_GPIO_OUT_IDX;
        GPIO.func_out_sel_cfg[pin].oen_sel = 1;
        GPIO.func_out_sel_cfg[pin].out_inv_sel = 0;
        GPIO.func_out_sel_cfg[pin].oen_inv_sel = 0;
        gpio_ll_set_level(&GPIO, pin, 0);
        gpio_ll_output_disable(&GPIO, pin);
        gpio_ll_input_enable(&GPIO, pin);
        gpio_ll_pullup_en(&GPIO, pin);
        gpio_ll_pulldown_dis(&GPIO, pin);
    }
}

void nih_display_pin_release(uint32_t pin, bool release) {
    if (pin != 31 && pin != 32) return;
    if (release) gpio_ll_output_disable(&GPIO, pin);
    else gpio_ll_output_enable(&GPIO, pin);
}
bool nih_display_pin_level(uint32_t pin) {
    return (pin == 31 || pin == 32) && gpio_ll_get_level(&GPIO, pin);
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
