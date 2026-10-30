/* Camera-facing channel 1 lease. CPU0 only; caller masks interrupts across
 * every operation, including the display owner's shared common-status path.
 * This initial interface only releases a lease that never started DMA.
 * After mark_started, retirement remains pinned until a separately qualified
 * DMA, FIFO and interrupt drain implementation is provided. */
#ifndef NIH_DW_DMA_CAMERA_H
#define NIH_DW_DMA_CAMERA_H
static uint32_t dw_camera_generation;
static uint32_t dw_camera_live;
static uint32_t dw_camera_fault;
static uint32_t dw_camera_denial;
static uint32_t dw_camera_signal_before, dw_camera_generation_before;
static bool dw_camera_started;
static uint32_t dw_camera_busy_flags(void) {
    return ((DW_GDMA.chen0.val & (1u << 1)) ? 1u : 0u) |
           (DW_GDMA.ch[1].int_sig_ena0.val ? 2u : 0u) |
           (DW_GDMA.ch[1].int_st_ena0.val ? 4u : 0u) |
           (dw_gdma_ll_channel_get_intr_status(&DW_GDMA, 1) ? 8u : 0u) |
           (dw_gdma_ll_channel_get_fifo_remain(&DW_GDMA, 1) ? 16u : 0u);
}
static uint32_t dw_camera_acquire(void) {
    dw_camera_denial = 0;
    if (dw_camera_live || dw_camera_generation == UINT32_MAX) { dw_camera_denial = 0x20; return 0; }
    /* Do not enable/reset a controller owned outside this domain, and never
     * inspect its channel registers with its clock off. */
    if (!dw_domain_channels) { dw_camera_denial = 0x40; return 0; }
    /* INT generation and signal enable reset to 1 on P4, even on an unused
     * channel. Ownership comes from the domain ledger, not those bits. */
    dw_camera_denial = dw_camera_busy_flags() & (1u | 8u | 16u);
    if (dw_camera_denial) return 0;
    if (!dw_domain_acquire(1)) { dw_camera_denial = 0x80; return 0; }
    dw_camera_signal_before = DW_GDMA.ch[1].int_sig_ena0.val;
    dw_camera_generation_before = DW_GDMA.ch[1].int_st_ena0.val;
    dw_camera_live = ++dw_camera_generation;
    dw_camera_fault = 0;
    dw_camera_started = false;
    return dw_camera_live;
}
static bool dw_camera_common(uint32_t token, uint32_t *out) {
    if (!out || !token || token != dw_camera_live) return false;
    dw_domain_refresh_common();
    dw_camera_fault |= dw_domain_take_common(1);
    *out = dw_camera_fault;
    return true;
}
static bool dw_camera_mark_started(uint32_t token) {
    if (!token || token != dw_camera_live || dw_camera_started || dw_camera_fault) return false;
    dw_domain_refresh_common();
    dw_camera_fault |= dw_domain_take_common(1);
    if (dw_camera_fault) return false;
    dw_camera_started = true; /* before the first write capable of DMA */
    return true;
}
static bool dw_camera_release_unused(uint32_t token) {
    uint32_t fault;
    if (!dw_camera_common(token, &fault) || fault || dw_camera_started ||
        (dw_camera_busy_flags() & (1u | 8u | 16u)) ||
        DW_GDMA.ch[1].int_sig_ena0.val != dw_camera_signal_before ||
        DW_GDMA.ch[1].int_st_ena0.val != dw_camera_generation_before) return false;
    if (!dw_domain_release(1)) return false;
    dw_camera_live = 0;
    return true;
}
#endif
