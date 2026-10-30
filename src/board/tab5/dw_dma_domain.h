/* DW-GDMA domain policy; callers must serialize on CPU0 with IRQs excluded.
 * A channel may be released only after it and its ISR are quiescent.
 * This is private to the display implementation until a shared owner exists. */
#ifndef NIH_DW_DMA_DOMAIN_H
#define NIH_DW_DMA_DOMAIN_H
static uint32_t dw_domain_channels;
static uint32_t dw_domain_common_pending[4];
static bool dw_domain_common_fault;
static void dw_domain_publish_common(uint32_t status) {
    if (!status) return;
    dw_domain_common_fault = true;
    for (uint32_t channel = 0; channel < 4; ++channel)
        if (dw_domain_channels & (1u << channel)) dw_domain_common_pending[channel] |= status;
}
/* All channel owners sample through this one path. In particular, admission
 * must not miss a fault that has reached hardware but not the display ISR. */
static void dw_domain_refresh_common(void) {
    if (!dw_domain_channels) return;
    const uint32_t status = dw_gdma_ll_get_common_intr_status(&DW_GDMA);
    dw_domain_publish_common(status);
    dw_gdma_ll_clear_common_intr(&DW_GDMA, status);
}
static bool dw_domain_acquire(uint32_t channel) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    if (channel >= 4 || (dw_domain_channels & (1u << channel))) return false;
    dw_domain_refresh_common();
    if (dw_domain_common_fault) return false;
    if (!dw_domain_channels) {
        /* Never reset another owner's pre-existing DMA controller. */
        if (dw_gdma_ll_is_bus_clock_enabled(0)) return false;
        dw_gdma_ll_enable_bus_clock(0, true);
        dw_gdma_ll_reset_register(0);
        dw_gdma_ll_enable_controller(&DW_GDMA, true);
        dw_gdma_ll_enable_intr_global(&DW_GDMA, true);
        dw_gdma_ll_enable_common_intr_generation(&DW_GDMA, UINT32_MAX, true);
        dw_gdma_ll_enable_common_intr_propagation(&DW_GDMA, UINT32_MAX, false);
        dw_gdma_ll_clear_common_intr(&DW_GDMA, UINT32_MAX);
    }
    dw_domain_channels |= 1u << channel;
    dw_domain_common_pending[channel] = 0;
    return true;
}
/* Snapshot once before clearing hardware. Every live channel must see faults;
 * no client can consume another client's copy. Call under the owner lock. */
static uint32_t dw_domain_take_common(uint32_t channel) {
    if (channel >= 4 || !(dw_domain_channels & (1u << channel))) return 0;
    const uint32_t result = dw_domain_common_pending[channel];
    dw_domain_common_pending[channel] = 0;
    return result;
}
/* Caller already proved the channel stopped. False means no state was changed. */
static bool dw_domain_release(uint32_t channel) {
    const int __DECLARE_RCC_ATOMIC_ENV = 0;
    (void)__DECLARE_RCC_ATOMIC_ENV;
    if (channel >= 4 || !(dw_domain_channels & (1u << channel))) return false;
    dw_domain_common_pending[channel] = 0;
    dw_domain_channels &= ~(1u << channel);
    if (!dw_domain_channels) {
        dw_gdma_ll_enable_intr_global(&DW_GDMA, false);
        dw_gdma_ll_enable_controller(&DW_GDMA, false);
        dw_gdma_ll_enable_bus_clock(0, false);
        dw_domain_common_fault = false;
    }
    return true;
}
#endif
