/* Opt-in native I2S0/AHB-DMA TX bring-up. Vendor LL definitions from pinned
 * ESP-IDF v5.4.4 (Apache-2.0); no linked IDF driver, allocator, IRQ or RTOS.
 * CPU0 alone owns I2S0 and AHB-DMA TX0 while this finite probe is active. */
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "hal/gpio_ll.h"
#pragma GCC diagnostic push
/* Four unused ESP-IDF ETM inline helpers end at HAL_ASSERT(false), which the
 * freestanding header defines without a noreturn fallback. Do not edit SDK. */
#pragma GCC diagnostic ignored "-Wreturn-type"
#include "hal/i2s_ll.h"
#pragma GCC diagnostic pop
#include "hal/ahb_dma_ll.h"
#include "soc/gpio_sig_map.h"
#include "soc/gdma_channel.h"
#ifndef NIH_AUDIO_AHB_DMA_BASE
#define NIH_AUDIO_AHB_DMA_BASE 0x50085000
#endif
#define NIH_AUDIO_STRING_INNER(value) #value
#define NIH_AUDIO_STRING(value) NIH_AUDIO_STRING_INNER(value)
_Static_assert(DR_REG_AHB_DMA_BASE == NIH_AUDIO_AHB_DMA_BASE, "AHB DMA is distinct from DW_GDMA at 0x50081000");
_Static_assert(DR_REG_I2S0_BASE == 0x500c6000, "native I2S0 register base");
_Static_assert(DR_REG_USB_WRAP_BASE == 0x50080000, "FS PHY pad register base");

__asm__(".global GPIO\n.set GPIO,0x500e0000\n"
        ".global IO_MUX\n.set IO_MUX,0x500e1000\n"
        ".global HP_SYS_CLKRST\n.set HP_SYS_CLKRST,0x500e6000\n"
        ".global LP_AON_CLKRST\n.set LP_AON_CLKRST,0x50111000\n"
        ".global I2S0\n.set I2S0,0x500c6000\n"
        ".global I2S1\n.set I2S1,0x500c7000\n"
        ".global I2S2\n.set I2S2,0x500c8000\n"
        ".global AHB_DMA\n.set AHB_DMA," NIH_AUDIO_STRING(NIH_AUDIO_AHB_DMA_BASE) "\n");
__asm__(".global USB_WRAP\n.set USB_WRAP,0x50080000\n");
static bool owned;
extern void nih_audio_stage(uint32_t code);
static void fence_io(void) { __asm__ volatile("fence iorw,iorw" ::: "memory"); }
static void output(unsigned pin, unsigned signal) {
    nih_audio_stage(0x200u + pin);
    // GPIO26/27 are also the unused FS-OTG PHY pads. The wrapper clock is
    // temporarily enabled by prepare, so LL can release the analog pad mux.
    gpio_ll_func_sel(&GPIO, (uint8_t)pin, 1);
    gpio_ll_pullup_dis(&GPIO, pin);
    gpio_ll_pulldown_dis(&GPIO, pin);
    GPIO.func_out_sel_cfg[pin].out_sel = signal;
    GPIO.func_out_sel_cfg[pin].oen_sel = 1;
    GPIO.func_out_sel_cfg[pin].out_inv_sel = 0;
    GPIO.func_out_sel_cfg[pin].oen_inv_sel = 0;
    gpio_ll_set_drive_capability(&GPIO, pin, 2);
    gpio_ll_output_enable(&GPIO, pin);
}

bool nih_audio_tx_prepare(uint32_t descriptor) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    if (owned || (descriptor & 63u) || descriptor < 0x4ff00000u || descriptor >= 0x4ff28000u) return false;
    nih_audio_stage(0x10);
    gdma_ll_enable_bus_clock(0, true);
    ahb_dma_ll_force_enable_reg_clock(&AHB_DMA, true);
    // This finite boot fixture owns the AHB controller's common memory ranges.
    // Refuse any existing RX/TX client; never reset another channel to obtain it.
    for (unsigned channel = 0; channel < 3; ++channel) {
        if (!ahb_dma_ll_tx_is_desc_fsm_idle(&AHB_DMA, channel) ||
            !ahb_dma_ll_rx_is_desc_fsm_idle(&AHB_DMA, channel) ||
            AHB_DMA.channel[channel].out.out_peri_sel.peri_out_sel_chn != GDMA_LL_INVALID_PERIPH_ID ||
            AHB_DMA.channel[channel].in.in_peri_sel.peri_in_sel_chn != GDMA_LL_INVALID_PERIPH_ID) return false;
    }
    owned = true;
    nih_audio_stage(0x11);
    ahb_dma_ll_set_default_memory_range(&AHB_DMA);
    i2s_ll_enable_bus_clock(0, true);
    i2s_ll_reset_register(0);
    nih_audio_stage(0x12);
    i2s_ll_tx_enable_clock(&I2S0);
    i2s_ll_mclk_bind_to_tx_clk(&I2S0);
    // Rev1.3 does not support the I2S PLL160 source. XTAL40M / (9+49/64)
    // gives 4.096 MHz MCLK; /8 gives 512 kHz BCLK; /32 gives 16 kHz LRCK.
    const hal_utils_clk_div_t divider = { .integer = 9, .numerator = 49, .denominator = 64 };
    i2s_ll_tx_clk_set_src(&I2S0, I2S_CLK_SRC_XTAL);
    i2s_ll_tx_set_mclk(&I2S0, &divider);
    i2s_ll_tx_set_bck_div_num(&I2S0, 8);
    nih_audio_stage(0x13);
    i2s_ll_tx_reset(&I2S0);
    i2s_ll_tx_reset_fifo(&I2S0);
    i2s_ll_tx_set_slave_mod(&I2S0, false);
    i2s_ll_tx_enable_std(&I2S0);
    i2s_ll_tx_set_sample_bit(&I2S0, 16, 16);
    i2s_ll_tx_set_half_sample_bit(&I2S0, 16);
    i2s_ll_tx_set_ws_width(&I2S0, 16);
    i2s_ll_tx_enable_msb_shift(&I2S0, true);
    i2s_ll_tx_enable_mono_mode(&I2S0, false);
    i2s_ll_tx_select_std_slot(&I2S0, I2S_STD_SLOT_BOTH);
    i2s_ll_tx_set_skip_mask(&I2S0, false);
    i2s_ll_tx_set_ws_idle_pol(&I2S0, false);
    i2s_ll_tx_set_bit_order(&I2S0, false);
    i2s_ll_tx_enable_left_align(&I2S0, true);
    i2s_ll_tx_enable_big_endian(&I2S0, false);
    i2s_ll_tx_reset_fifo_sync_counter(&I2S0);
    i2s_ll_tx_reset_bclk_sync_counter(&I2S0);
    nih_audio_stage(0x14);
    I2S0.int_ena.val = 0;
    I2S0.int_clr.val = 0xffffffffu;
    ahb_dma_ll_tx_reset_channel(&AHB_DMA, 0);
    ahb_dma_ll_tx_enable_interrupt(&AHB_DMA, 0, 0x0fu, false);
    ahb_dma_ll_tx_clear_interrupt_status(&AHB_DMA, 0, 0x0fu);
    ahb_dma_ll_tx_enable_owner_check(&AHB_DMA, 0, true);
    ahb_dma_ll_tx_enable_auto_write_back(&AHB_DMA, 0, true);
    ahb_dma_ll_tx_enable_data_burst(&AHB_DMA, 0, false);
    ahb_dma_ll_tx_enable_descriptor_burst(&AHB_DMA, 0, false);
    ahb_dma_ll_tx_set_eof_mode(&AHB_DMA, 0, 1); // EOF after data leaves DMA FIFO.
    ahb_dma_ll_tx_set_priority(&AHB_DMA, 0, 1);
    ahb_dma_ll_tx_connect_to_periph(&AHB_DMA, 0, GDMA_TRIG_PERIPH_I2S, SOC_GDMA_TRIG_PERIPH_I2S0);
    ahb_dma_ll_tx_set_desc_addr(&AHB_DMA, 0, descriptor);
    nih_audio_stage(0x15);
    const bool usb_bus = HP_SYS_CLKRST.soc_clk_ctrl1.reg_usb_otg11_sys_clk_en;
    const bool usb_48m = LP_AON_CLKRST.hp_usb_clkrst_ctrl0.usb_otg11_48m_clk_en;
    HP_SYS_CLKRST.soc_clk_ctrl1.reg_usb_otg11_sys_clk_en = 1;
    LP_AON_CLKRST.hp_usb_clkrst_ctrl0.usb_otg11_48m_clk_en = 1;
    fence_io();
    output(30, I2S0_MCLK_PAD_OUT_IDX);
    output(27, I2S0_O_BCK_PAD_OUT_IDX);
    output(29, I2S0_O_WS_PAD_OUT_IDX);
    output(26, I2S0_O_SD_PAD_OUT_IDX);
    LP_AON_CLKRST.hp_usb_clkrst_ctrl0.usb_otg11_48m_clk_en = usb_48m;
    HP_SYS_CLKRST.soc_clk_ctrl1.reg_usb_otg11_sys_clk_en = usb_bus;
    fence_io();
    return true;
}

bool nih_audio_tx_start(void) {
    if (!owned) return false;
    // The SDK's helper spins without a bound. Keep a finite update handshake.
    I2S0.tx_conf.tx_update = 1;
    for (unsigned attempt = 0; attempt < 8192; ++attempt) {
        if (!I2S0.tx_conf.tx_update) {
            ahb_dma_ll_tx_start(&AHB_DMA, 0);
            fence_io();
            I2S0.tx_conf.tx_start = 1;
            fence_io();
            return true;
        }
    }
    return false;
}

void nih_audio_tx_status(uint32_t words[5]) {
    if (!owned) { for (unsigned i = 0; i < 5; ++i) words[i] = 0; return; }
    words[0] = ahb_dma_ll_tx_get_interrupt_status(&AHB_DMA, 0, true);
    words[1] = i2s_ll_tx_get_bclk_sync_count(&I2S0);
    words[2] = i2s_ll_tx_get_fifo_sync_count(&I2S0);
    words[3] = ahb_dma_ll_tx_get_eof_desc_addr(&AHB_DMA, 0);
    words[4] = ahb_dma_ll_tx_is_desc_fsm_idle(&AHB_DMA, 0);
}

bool nih_audio_tx_stop(void) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    if (!owned) return true;
    i2s_ll_tx_stop(&I2S0);
    ahb_dma_ll_tx_stop(&AHB_DMA, 0);
    fence_io();
    bool parked = false;
    for (unsigned attempt = 0; attempt < 8192; ++attempt) {
        if (ahb_dma_ll_tx_is_desc_fsm_idle(&AHB_DMA, 0) && I2S0.state.tx_idle) { parked = true; break; }
    }
    if (!parked) return false; // Retain ownership and buffers on failure.
    ahb_dma_ll_tx_enable_interrupt(&AHB_DMA, 0, 0x0fu, false);
    ahb_dma_ll_tx_disconnect_from_periph(&AHB_DMA, 0);
    ahb_dma_ll_tx_set_desc_addr(&AHB_DMA, 0, 0);
    i2s_ll_tx_disable_clock(&I2S0);
    for (unsigned pin = 26; pin <= 30; ++pin) if (pin != 28) gpio_ll_output_disable(&GPIO, pin);
    owned = false;
    fence_io();
    return true;
}
