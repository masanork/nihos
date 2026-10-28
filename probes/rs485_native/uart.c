/* Native Tab5 UART1/RS485 fixture. Pinned ESP-IDF v5.4.4 LL declarations
 * (Apache-2.0); no linked IDF UART driver, allocator, interrupt or RTOS. */
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "hal/gpio_ll.h"
#include "hal/uart_ll.h"
#include "soc/gpio_sig_map.h"
#include "soc/gpio_pins.h"
#ifndef NIH_RS485_UART_BASE
#define NIH_RS485_UART_BASE 0x500cb000
#endif
#define NIH_STRING_INNER(value) #value
#define NIH_STRING(value) NIH_STRING_INNER(value)
_Static_assert(NIH_RS485_UART_BASE == DR_REG_UART1_BASE, "RS485 must use UART1, never UART0");
_Static_assert(DR_REG_USB_WRAP_BASE == 0x50080000, "GPIO mux helper USB wrapper alias");
_Static_assert(SOC_UART_FIFO_LEN == 128, "bounded UART FIFO geometry");
__asm__(".global GPIO\n.set GPIO,0x500e0000\n"
        ".global IO_MUX\n.set IO_MUX,0x500e1000\n"
        ".global HP_SYS_CLKRST\n.set HP_SYS_CLKRST,0x500e6000\n"
        ".global USB_WRAP\n.set USB_WRAP,0x50080000\n"
        ".global UART0\n.set UART0,0x500ca000\n"
        ".global UART1\n.set UART1," NIH_STRING(NIH_RS485_UART_BASE) "\n"
        ".global UART2\n.set UART2,0x500cc000\n"
        ".global UART3\n.set UART3,0x500cd000\n"
        ".global UART4\n.set UART4,0x500ce000\n");
static bool owned;
static bool peer;
static bool was_closed;
static uint32_t diagnostic[4];
static bool failed(uint32_t stage, uint32_t a, uint32_t b, uint32_t c) {
    if (!diagnostic[0]) { diagnostic[0] = stage; diagnostic[1] = a; diagnostic[2] = b; diagnostic[3] = c; }
    return false;
}
void nih_rs485_diagnostic(uint32_t words[4]) { for (unsigned i = 0; i < 4; ++i) words[i] = diagnostic[i]; }
static void fence_io(void) { __asm__ volatile("fence iorw,iorw" ::: "memory"); }
static bool update(void) {
    UART1.reg_update.reg_update = 1;
    for (unsigned n = 0; n < 8192; ++n) if (!UART1.reg_update.reg_update) return true;
    return false;
}
static void output(unsigned pin, unsigned signal, bool high) {
    gpio_ll_set_level(&GPIO, pin, high); // Latch before enabling the output.
    gpio_ll_func_sel(&GPIO, (uint8_t)pin, 1);
    gpio_ll_pullup_dis(&GPIO, pin); gpio_ll_pulldown_dis(&GPIO, pin);
    gpio_ll_od_disable(&GPIO, pin);
    GPIO.func_out_sel_cfg[pin].out_sel = signal;
    GPIO.func_out_sel_cfg[pin].oen_sel = 1;
    GPIO.func_out_sel_cfg[pin].out_inv_sel = 0;
    GPIO.func_out_sel_cfg[pin].oen_inv_sel = 0;
    gpio_ll_output_enable(&GPIO, pin);
}
bool nih_rs485_dir_low(void) {
    return !(GPIO.out1.val & 4u) && (GPIO.enable1.val & 4u) &&
        GPIO.func_out_sel_cfg[34].out_sel == SIG_GPIO_OUT_IDX &&
        GPIO.func_out_sel_cfg[34].oen_sel && !gpio_ll_get_level(&GPIO, 34);
}
bool nih_rs485_open(uint32_t mode) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0; (void)__DECLARE_RCC_ATOMIC_ENV;
    if (owned || mode < 1 || mode > 3) return failed(1, owned, mode, 0);
    // Reset leaves UART1 APB/system gates enabled on this silicon. Gates
    // alone do not establish a client. UART1 is statically reserved for this
    // boot fixture; adopt only an inactive, unconfigured FIFO/interrupt state.
    // This is not a runtime UART resource-sharing/ownership allocator.
    if (uart_ll_is_enabled(1) && (UART1.conf0_sync.mem_clk_en || UART1.int_ena.val ||
        UART1.rs485_conf_sync.rs485_en || !uart_ll_is_tx_idle(&UART1) || uart_ll_get_rxfifo_len(&UART1)))
        return failed(2, UART1.conf0_sync.val, UART1.status.val, UART1.int_ena.val);
    owned = true; was_closed = false; peer = mode == 2;
    output(34, SIG_GPIO_OUT_IDX, false); // /RE and DE tied: low=receive.
    gpio_ll_input_enable(&GPIO, 34);
    if (!nih_rs485_dir_low()) return failed(3, GPIO.out1.val, GPIO.enable1.val, GPIO.in1.val);
    uart_ll_enable_bus_clock(1, true);
    uart_ll_reset_register(1);
    uart_ll_sclk_enable(&UART1);
    uart_ll_set_sclk(&UART1, (soc_module_clk_t)UART_SCLK_XTAL);
    HAL_FORCE_MODIFY_U32_REG_FIELD(HP_SYS_CLKRST.peri_clk_ctrl112, reg_uart1_sclk_div_num, 0);
    const uint32_t divider = (40000000u << 4) / 115200u;
    UART1.clkdiv_sync.clkdiv = divider >> 4;
    UART1.clkdiv_sync.clkdiv_frag = divider & 15u;
    UART1.conf0_sync.bit_num = 3; UART1.conf0_sync.stop_bit_num = 1;
    UART1.conf0_sync.parity_en = 0; UART1.conf0_sync.tx_flow_en = 0;
    UART1.conf0_sync.loopback = mode == 1;
    UART1.conf0_sync.mem_clk_en = 1;
    UART1.conf0_sync.autobaud_en = 0;
    UART1.hwfc_conf_sync.rx_flow_en = 0;
    UART1.rs485_conf_sync.rs485_en = 0; // Direction is explicitly owned by CPU0.
    UART1.idle_conf_sync.tx_idle_num = 0;
    UART1.int_ena.val = 0; UART1.int_clr.val = 0x000fffffu;
    UART1.conf0_sync.txfifo_rst = 1; UART1.conf0_sync.rxfifo_rst = 1;
    if (!update()) return failed(4, UART1.reg_update.val, UART1.clk_conf.val, HP_SYS_CLKRST.peri_clk_ctrl111.val);
    UART1.conf0_sync.txfifo_rst = 0; UART1.conf0_sync.rxfifo_rst = 0;
    if (!update()) return failed(5, UART1.reg_update.val, UART1.clk_conf.val, HP_SYS_CLKRST.peri_clk_ctrl111.val);
    if (peer) {
        output(20, UART1_TXD_PAD_OUT_IDX, true);
        gpio_ll_func_sel(&GPIO, 21, 1); gpio_ll_output_disable(&GPIO, 21);
        gpio_ll_input_enable(&GPIO, 21);
        gpio_ll_pullup_dis(&GPIO, 21); gpio_ll_pulldown_dis(&GPIO, 21);
        GPIO.func_in_sel_cfg[UART1_RXD_PAD_IN_IDX].in_sel = 21;
    } else {
        // Internal tests never map UART TX to the transceiver. External DE
        // stays low throughout. Constant-high RX isolates no-loopback control.
        GPIO.func_in_sel_cfg[UART1_RXD_PAD_IN_IDX].in_sel = GPIO_MATRIX_CONST_ONE_INPUT;
    }
    GPIO.func_in_sel_cfg[UART1_RXD_PAD_IN_IDX].sig_in_sel = 1;
    GPIO.func_in_sel_cfg[UART1_RXD_PAD_IN_IDX].in_inv_sel = 0;
    fence_io();
    if (!uart_ll_is_tx_idle(&UART1) || uart_ll_get_rxfifo_len(&UART1) != 0) return failed(6, UART1.status.val, UART1.fsm_status.val, UART1.int_raw.val);
    return true;
}
bool nih_rs485_direction(bool tx) {
    if (!owned) return false;
    gpio_ll_set_level(&GPIO, 34, tx && peer);
    fence_io();
    for (unsigned n = 0; n < 8192; ++n) {
        if (tx && peer ? gpio_ll_get_level(&GPIO, 34) != 0 : nih_rs485_dir_low()) return true;
    }
    return failed(9, GPIO.out1.val, GPIO.enable1.val, GPIO.in1.val);
}
uint32_t nih_rs485_errors(void) {
    return owned ? uart_ll_get_intraw_mask(&UART1) & (UART_INTR_PARITY_ERR | UART_INTR_FRAM_ERR | UART_INTR_RXFIFO_OVF | UART_INTR_BRK_DET) : 0;
}
bool nih_rs485_writable(void) { return owned && uart_ll_get_txfifo_len(&UART1) > 0; }
bool nih_rs485_readable(void) { return owned && uart_ll_get_rxfifo_len(&UART1) > 0; }
bool nih_rs485_tx_idle(void) { return owned && uart_ll_is_tx_idle(&UART1); }
bool nih_rs485_write(uint8_t byte) {
    if (!nih_rs485_writable()) return false;
    UART1.fifo.val = byte; // Full 32-bit store, never a FIFO read-modify-write.
    return true;
}
uint32_t nih_rs485_read(void) { return nih_rs485_readable() ? UART1.fifo.val & 255u : 0x100u; }
bool nih_rs485_close(void) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0; (void)__DECLARE_RCC_ATOMIC_ENV;
    if (!owned) return was_closed;
    gpio_ll_set_level(&GPIO, 34, 0); fence_io();
    // Also runs on timeout: drop DE immediately, then reset only our UART1
    // to cancel any unfinished byte/FIFO. A failed exchange is never a pass.
    uart_ll_reset_register(1); fence_io();
    bool idle = false;
    for (unsigned n = 0; n < 8192; ++n) if (uart_ll_is_tx_idle(&UART1) && uart_ll_get_rxfifo_len(&UART1) == 0) { idle = true; break; }
    if (!idle) return failed(7, UART1.status.val, UART1.fsm_status.val, UART1.clk_conf.val);
    UART1.int_ena.val = 0; UART1.int_clr.val = 0x000fffffu;
    uart_ll_sclk_disable(&UART1);
    uart_ll_enable_bus_clock(1, false);
    if (peer) { gpio_ll_output_disable(&GPIO, 20); gpio_ll_input_disable(&GPIO, 21); }
    GPIO.func_in_sel_cfg[UART1_RXD_PAD_IN_IDX].in_sel = GPIO_MATRIX_CONST_ONE_INPUT;
    fence_io();
    if (!nih_rs485_dir_low() || uart_ll_is_enabled(1)) return failed(8, GPIO.out1.val, GPIO.enable1.val, GPIO.in1.val);
    owned = false; was_closed = true;
    return true;
}
bool nih_rs485_closed(void) { return was_closed && !owned; }
