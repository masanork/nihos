/* Replay production DMA retirement, including a stuck channel; no card data. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#define NIH_NATIVE_CARD_AUTO 1
#define SCANOUT_RETIRE_FENCE() ((void)0)
static struct { struct { uint32_t val; } chen0; } DW_GDMA;
static struct { struct { uint32_t val; } out; } GPIO;
static unsigned MIPI_DSI_BRIDGE;
static bool dma_owned, ui_enabled, notice_enabled, pause_requested, stuck;
static uint32_t fault, completions, backlight_offs;
static unsigned restarts, disabled, stopped_domains;
static bool stop_dma(bool blank);
static bool restart_dma(void) { ++restarts; return true; }
static void gpio_ll_set_level(void *io, unsigned pin, unsigned level) {
    (void)io; assert(pin == 22);
    if (level) GPIO.out.val |= 1u << 22; else GPIO.out.val &= ~(1u << 22);
}
static void dw_gdma_ll_channel_enable_intr_propagation(void *io, unsigned channel, uint32_t mask, bool on) {
    (void)io; assert(channel == 0 && mask == UINT32_MAX && !on);
}
static void dw_gdma_ll_channel_enable(void *io, unsigned channel, bool on) {
    (void)io; assert(channel == 0 && !on); ++disabled;
    if (!stuck) DW_GDMA.chen0.val = 0;
}
static void mipi_dsi_brg_ll_enable_interrupt(void *io, uint32_t mask, bool on) {
    (void)io; assert(mask == UINT32_MAX && !on);
}
static void mipi_dsi_brg_ll_enable_dpi_output(void *io, bool on) { (void)io; assert(!on); }
static void mipi_dsi_brg_ll_enable(void *io, bool on) { (void)io; assert(!on); }
static void mipi_dsi_ll_enable_dpi_clock(unsigned id, bool on) { assert(id == 0 && !on); }
static void dw_gdma_ll_enable_intr_global(void *io, bool on) { (void)io; assert(!on); }
static void dw_gdma_ll_enable_controller(void *io, bool on) { (void)io; assert(!on); }
static void dw_gdma_ll_enable_bus_clock(unsigned id, bool on) { assert(id == 0 && !on); ++stopped_domains; }
#include "../../src/board/tab5/scanout_retire.h"
static void active(void) {
    dma_owned = ui_enabled = notice_enabled = true;
    pause_requested = stuck = false; fault = 0; completions = 2;
    backlight_offs = restarts = disabled = stopped_domains = 0;
    GPIO.out.val = 1u << 22; DW_GDMA.chen0.val = 1;
}
int main(void) {
    active();
    assert(complete_dma_frame() && restarts == 1 && dma_owned);
    assert(nih_display_scanout_pause_request());
    assert(!nih_display_scanout_pause_request() && !nih_display_scanout_paused());
    assert(dma_owned && disabled == 0); /* Request alone cannot release SRAM. */
    assert(complete_dma_frame()); /* IRQ calls this only at DMA EOF. */
    assert(nih_display_scanout_paused() && !dma_owned && !ui_enabled && !notice_enabled);
    assert(disabled == 1 && stopped_domains == 1 && restarts == 1);
    nih_display_backlight(true); /* IRQ epilogue must not blank a pause. */
    assert(GPIO.out.val == (1u << 22) && backlight_offs == 0);
    assert(nih_display_scanout_stop() && !nih_display_scanout_paused());
    assert(!GPIO.out.val && backlight_offs == 1);
    active(); stuck = true;
    assert(nih_display_scanout_pause_request() && !complete_dma_frame());
    assert(!nih_display_scanout_paused() && dma_owned && ui_enabled && notice_enabled);
    assert(stopped_domains == 0); /* Timeout retains DMA/domain ownership. */
    fault = 8; nih_display_backlight(true);
    assert(!GPIO.out.val && backlight_offs == 1);
    assert(!nih_display_scanout_stop() && dma_owned);
    active(); fault = 4;
    assert(!nih_display_scanout_pause_request());
    nih_display_backlight(true); assert(!GPIO.out.val);
    active(); completions = 1;
    nih_display_backlight(true); assert(!GPIO.out.val);
    puts("Scene retirement replay passed: EOF only, pause stays lit, timeout retains ownership, faults blank");
}
