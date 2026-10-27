/* SPDX-License-Identifier: MIT
 * Register-only boundary using ESP-IDF v5.4.4 Apache-2.0 LL headers.
 * Boot CPU0 owns GPIO31/32 and UTMI before CPU1 starts. No SDK runtime.
 */
#include <stddef.h>
#include "hal/gpio_ll.h"
#include "hal/usb_utmi_ll.h"
#include "soc/gpio_sig_map.h"

__asm__(".global GPIO\n.set GPIO,0x500e0000\n"
        ".global IO_MUX\n.set IO_MUX,0x500e1000\n"
        ".global HP_SYSTEM\n.set HP_SYSTEM,0x500e5000\n"
        ".global HP_SYS_CLKRST\n.set HP_SYS_CLKRST,0x500e6000\n"
        ".global LP_AON_CLKRST\n.set LP_AON_CLKRST,0x50111000\n"
        ".global USB_UTMI\n.set USB_UTMI,0x5009c000\n");

void nih_usb_i2c_init(void) {
    for (unsigned pin = 31; pin <= 32; ++pin) {
        gpio_ll_output_disable(&GPIO, pin);
        IO_MUX.gpio[pin].mcu_sel = 1;
        GPIO.func_out_sel_cfg[pin].out_sel = SIG_GPIO_OUT_IDX;
        GPIO.func_out_sel_cfg[pin].oen_sel = 1;
        gpio_ll_set_level(&GPIO, pin, 0);
        gpio_ll_input_enable(&GPIO, pin);
        gpio_ll_pullup_en(&GPIO, pin);
        gpio_ll_pulldown_dis(&GPIO, pin);
    }
}
void nih_usb_pin_release(unsigned pin, bool release) {
    if (release) gpio_ll_output_disable(&GPIO, pin);
    else gpio_ll_output_enable(&GPIO, pin);
}
bool nih_usb_pin_level(unsigned pin) {
    return gpio_ll_get_level(&GPIO, pin) != 0;
}
void nih_usb_phy_init(void) {
    // P4 rev1.3: host pulldowns are controlled by OTG, unlike rev3.
    _usb_utmi_ll_enable_bus_clock(true);
    _usb_utmi_ll_reset_register();
    usb_utmi_ll_enable_precise_detection(true);
    usb_utmi_ll_configure_ls(&USB_UTMI, true);
}
void nih_usb_phy_stop(void) {
    // Reset the DMA engine before returning ownership of its SRAM buffers.
    _usb_utmi_ll_reset_register();
    _usb_utmi_ll_enable_bus_clock(false);
}
