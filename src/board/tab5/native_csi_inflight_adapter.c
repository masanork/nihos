/* Register primitives for an experimental channel-1 in-flight stop observer.
 * The native diagnostic uses these operations under the serialized owner.
 * The caller must own the domain,
 * channel, bridge, sensor and pinned frame, mask its ISR, and separately latch
 * controller-common faults. These helpers neither stop the sensor nor release
 * resources. A read-only observation does not prove AXI/cache retirement.
 * Register definitions: ESP-IDF v5.4.4 ESP32-P4 DW-GDMA LL.
 */
#include <stdlib.h>
#include <stdbool.h>
#include <stdint.h>
#include "hal/dw_gdma_ll.h"
#include "hal/mipi_csi_brg_ll.h"
#define CH 1u
#define DISABLED (1u << 30)
#define EVENTS 0x003f7fe2u /* writable done and error status enables */
#define SIGNALS 0xf83f7ffbu /* writable signal enables; excludes RO/reserved */
#ifndef INFLIGHT_ENABLED
#define INFLIGHT_ENABLED() ((DW_GDMA.chen0.val & (1u << CH)) != 0)
#endif
#ifndef INFLIGHT_CLEAR
#define INFLIGHT_CLEAR(mask) dw_gdma_ll_channel_clear_intr(&DW_GDMA, CH, (mask))
#endif
#ifndef INFLIGHT_DISABLE
#define INFLIGHT_DISABLE() dw_gdma_ll_channel_enable(&DW_GDMA, CH, false)
#endif
#ifndef INFLIGHT_FENCE
#define INFLIGHT_FENCE() __asm__ volatile("fence iorw,iorw" ::: "memory")
#endif
bool nih_csi_inflight_active(void) { return INFLIGHT_ENABLED(); }
bool nih_csi_inflight_generation(void) {
    const uint32_t enabled = DW_GDMA.ch[CH].int_st_ena0.val;
    return (enabled & (EVENTS | DISABLED)) == (EVENTS | DISABLED);
}
bool nih_csi_inflight_masked(void) { return !(DW_GDMA.ch[CH].int_sig_ena0.val & SIGNALS); }
uint32_t nih_csi_inflight_status(void) { return dw_gdma_ll_channel_get_intr_status(&DW_GDMA, CH); }
void nih_csi_inflight_clear_disabled(void) {
    INFLIGHT_CLEAR(DISABLED); /* never clear completion, error, or another channel */
    INFLIGHT_FENCE();
}
bool nih_csi_inflight_bridge_off(void) {
    mipi_csi_brg_ll_enable(&MIPI_CSI_BRIDGE, false);
    INFLIGHT_FENCE();
    return !MIPI_CSI_BRIDGE.csi_en.csi_brg_en;
}
bool nih_csi_inflight_request_disable(void) {
    /* Refuse after a racing natural completion or if interrupt coverage fell
     * away. Caller must stop the producer and bridge before invoking this. */
    const uint32_t status = nih_csi_inflight_status();
    if (!INFLIGHT_ENABLED() || MIPI_CSI_BRIDGE.csi_en.csi_brg_en ||
        !nih_csi_inflight_generation() || !nih_csi_inflight_masked() ||
        (status & (EVENTS | DISABLED))) return false;
    INFLIGHT_DISABLE();
    INFLIGHT_FENCE();
    return true; /* acceptance is not confirmation */
}
uint32_t nih_csi_inflight_fifo(void) { return dw_gdma_ll_channel_get_fifo_remain(&DW_GDMA, CH); }
