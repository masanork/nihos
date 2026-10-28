/* Shared production DMA-retirement and illumination policy. Ordinary scene
 * changes retire at DMA EOF; emergency shutdown still blanks immediately.
 * A timed-out retirement must retain ownership and prohibit SRAM reuse. */
#ifndef SCANOUT_RETIRE_FENCE
#define SCANOUT_RETIRE_FENCE() __asm__ volatile("fence rw,rw" ::: "memory")
#endif
static void dark(void) {
#if NIH_NATIVE_CARD_AUTO
    if (GPIO.out.val & (1u << 22)) ++backlight_offs;
#endif
    gpio_ll_set_level(&GPIO, 22, 0);
}
void nih_display_backlight(bool enable) {
    if (enable && (dma_owned || pause_requested) && completions >= 2 && !fault) gpio_ll_set_level(&GPIO, 22, 1);
    else dark();
}
bool nih_display_scanout_pause_request(void) {
    if (!dma_owned || fault || pause_requested) return false;
    SCANOUT_RETIRE_FENCE();
    pause_requested = true;
    return true;
}
bool nih_display_scanout_paused(void) { return pause_requested && !dma_owned && !fault; }

static bool stop_dma(bool blank) {
    if (blank) dark();
    if (!dma_owned) return true;
    dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, 0, UINT32_MAX, false);
    dw_gdma_ll_channel_enable(&DW_GDMA, 0, false);
    for (unsigned poll = 0; poll < 100000; ++poll) {
        if (!(DW_GDMA.chen0.val & 1)) {
            const int __DECLARE_RCC_ATOMIC_ENV = 0;
            (void)__DECLARE_RCC_ATOMIC_ENV;
            // The host must stop consuming DPI before its clock/data source
            // is retired. Otherwise a warm update latches dpi_buff_pld_under.
            mipi_dsi_host_ll_enable_video_mode(&MIPI_DSI_HOST, false);
            mipi_dsi_brg_ll_enable_interrupt(&MIPI_DSI_BRIDGE, UINT32_MAX, false);
            mipi_dsi_brg_ll_enable_dpi_output(&MIPI_DSI_BRIDGE, false);
            mipi_dsi_brg_ll_enable(&MIPI_DSI_BRIDGE, false);
            mipi_dsi_ll_enable_dpi_clock(0, false);
            dw_gdma_ll_enable_intr_global(&DW_GDMA, false);
            dw_gdma_ll_enable_controller(&DW_GDMA, false);
            dw_gdma_ll_enable_bus_clock(0, false);
            dma_owned = false;
            ui_enabled = false;
#if NIH_NATIVE_CARD_AUTO
            notice_enabled = false;
#endif
            return true;
        }
    }
    /* Keep this channel/domain and its private memory retired on timeout. */
    return false;
}
bool nih_display_scanout_stop(void) { pause_requested = false; return stop_dma(true); }

static bool complete_dma_frame(void) {
    return pause_requested ? stop_dma(false) : restart_dma();
}
