/* Single-frame CSI DMA polling experiment; not linked into normal firmware.
 * CPU0's serialized owner must hold channel 1 and the CSI bridge, and perform
 * cache handoff and sensor stream-on/off. No global interrupt clear or reset.
 * LL register facts: ESP-IDF v5.4.4 CSI and DW-GDMA implementations.
 */
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include "hal/dw_gdma_ll.h"
#include "hal/mipi_csi_brg_ll.h"
#include "hal/mipi_csi_ll.h"

#define CSI_RX_CHANNEL 1u
#define CSI_DMA_ERRORS 0x07ffffe0u
#define CSI_DMA_DONE DW_GDMA_LL_CHANNEL_EVENT_DMA_TFR_DONE
#define CSI_DMA_EVENTS (CSI_DMA_ERRORS | CSI_DMA_DONE)
/* P4 writable event-enable fields; excludes reserved and RO bit 25. */
#define CSI_DMA_WRITABLE_EVENTS 0x003f7fe2u
#define CSI_DMA_WRITABLE_SIGNALS 0xf83f7ffbu
#ifndef CSI_DMA_ENABLE
#define CSI_DMA_ENABLE(enable) dw_gdma_ll_channel_enable(&DW_GDMA, CSI_RX_CHANNEL, (enable))
#endif
#ifndef CSI_DMA_ENABLED
#define CSI_DMA_ENABLED() ((DW_GDMA.chen0.val & (1u << CSI_RX_CHANNEL)) != 0)
#endif
#ifndef CSI_DMA_CLEAR
#define CSI_DMA_CLEAR(events) dw_gdma_ll_channel_clear_intr(&DW_GDMA, CSI_RX_CHANNEL, (events))
#endif
#ifndef CSI_DMA_FENCE
#define CSI_DMA_FENCE() __asm__ volatile("fence iorw,iorw" ::: "memory")
#endif

typedef enum { CSI_RX_IDLE, CSI_RX_ARMED, CSI_RX_RUNNING, CSI_RX_STOPPED, CSI_RX_PINNED } csi_rx_state;
typedef struct { csi_rx_state state; uint32_t events; } csi_rx;
static uint32_t stop_status_before_clear;
#include "camera_dma_pool.h"
extern int32_t nih_csi_dma_configure(uint32_t, uint32_t, uint32_t);
static camera_dma_pool stream_pool;
static uint32_t stream_addresses[2], stream_fault;
static bool stream_configured, stream_stop, stream_drained;
#if defined(__riscv)
#define STREAM_FOREGROUND __attribute__((section(".flash.text.devices")))
#else
#define STREAM_FOREGROUND
#endif
STREAM_FOREGROUND bool nih_csi_stream_begin(uint32_t a, uint32_t b) {
    if (stream_configured || CSI_DMA_ENABLED() || MIPI_CSI_BRIDGE.csi_en.csi_brg_en ||
        a < 0x48030000u || b < 0x48030000u || a > 0x4c000000u - 921600u || b > 0x4c000000u - 921600u ||
        (a & 63u) || (b & 63u) || !((uint64_t)a + 921600u <= b || (uint64_t)b + 921600u <= a)) return false;
    camera_pool_init(&stream_pool);
    stream_addresses[0] = a; stream_addresses[1] = b;
    stream_fault = 0; stream_stop = false; stream_drained = false;
    stream_configured = true;
    return true;
}
STREAM_FOREGROUND void nih_csi_stream_stop(void) { if (stream_configured) stream_stop = true; }
STREAM_FOREGROUND void nih_csi_stream_abort(void) {
    if (!stream_configured) return;
    stream_fault |= 0x100u;
    dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, 1, UINT32_MAX, false);
    mipi_csi_brg_ll_enable(&MIPI_CSI_BRIDGE, false);
    CSI_DMA_ENABLE(false);
    CSI_DMA_FENCE();
    stream_drained = true; /* fault remains latched; no retirement/reuse follows */
}
STREAM_FOREGROUND uint32_t nih_csi_stream_state(uint32_t kind) {
    switch (kind) {
    case 0: return stream_configured;
    case 1: return stream_pool.generation;
    case 2: return stream_pool.dropped;
    case 3: return stream_fault;
    case 4: return stream_drained;
    default: return 0;
    }
}
STREAM_FOREGROUND uint32_t nih_csi_stream_borrow(uint32_t *generation) {
    if (!stream_configured || stream_fault || stream_stop) return 0;
    const int slot = camera_pool_borrow(&stream_pool, generation);
    return slot < 0 ? 0 : stream_addresses[slot];
}
STREAM_FOREGROUND bool nih_csi_stream_release(uint32_t generation) {
    return stream_configured && camera_pool_release(&stream_pool, generation);
}
STREAM_FOREGROUND bool nih_csi_stream_end(void) {
    if (!stream_configured || CSI_DMA_ENABLED() || MIPI_CSI_BRIDGE.csi_en.csi_brg_en || stream_pool.borrowed >= 0) return false;
    stream_configured = false;
    return true;
}
/* Shared DW-GDMA IRQ, CPU0 with interrupts masked. Like ESP-IDF v5.4.4's
 * CSI completion callback, rearm channel 1 before foreground consumption.
 * Both payloads are pre-cleaned and subsequently CPU read-only; consumers
 * invalidate sampled cache lines after borrowing a completed, inactive slot. */
void nih_csi_stream_irq(uint32_t common) {
    if (!stream_configured || stream_drained) return;
    const uint32_t events = dw_gdma_ll_channel_get_intr_status(&DW_GDMA, 1) & CSI_DMA_EVENTS;
    const uint32_t bridge = MIPI_CSI_BRIDGE.int_raw.val & 0x1fu;
    if (!events && !common && !bridge) return;
    CSI_DMA_CLEAR(events);
    if (common || bridge || (events & CSI_DMA_ERRORS)) stream_fault |= common | events | (bridge << 24);
    if (!(events & CSI_DMA_DONE) && !stream_fault) return;
    CSI_DMA_ENABLE(false);
    CSI_DMA_FENCE();
    if (CSI_DMA_ENABLED()) stream_fault |= 1u;
    if (stream_fault || stream_stop) {
        mipi_csi_brg_ll_enable(&MIPI_CSI_BRIDGE, false);
        dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, 1, UINT32_MAX, false);
        stream_drained = true;
        return;
    }
    const int next = camera_pool_complete(&stream_pool);
    if (next < 0 || nih_csi_dma_configure(stream_addresses[next], stream_addresses[next], 921600) != 0) {
        stream_fault |= 4u;
        mipi_csi_brg_ll_enable(&MIPI_CSI_BRIDGE, false);
        dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, 1, UINT32_MAX, false);
        stream_drained = true;
        return;
    }
    CSI_DMA_ENABLE(true);
    CSI_DMA_FENCE();
    if (!CSI_DMA_ENABLED()) stream_fault |= 8u;
}

/* Prototype restart of a successfully completed transfer on the SAME retained
 * channel and frame. This does not retire the lease or authorize allocation reuse.
 * Caller validates its domain token and completed capture before/after this. */
uint32_t nih_csi_dma_retained_flags(void) {
    CSI_DMA_FENCE();
    return (!DW_GDMA.cfg0.dmac_en ? 1u : 0u) | (CSI_DMA_ENABLED() ? 2u : 0u) |
        /* Clock-gated bridge register reads are not meaningful. Preparation
         * re-enables its clock and checks the disabled bridge before DMA arm. */
        ((HP_SYS_CLKRST.soc_clk_ctrl1.reg_csi_brg_sys_clk_en && MIPI_CSI_BRIDGE.csi_en.csi_brg_en) ? 4u : 0u) |
        (dw_gdma_ll_channel_get_fifo_remain(&DW_GDMA, CSI_RX_CHANNEL) ? 8u : 0u) |
        (dw_gdma_ll_channel_get_intr_status(&DW_GDMA, CSI_RX_CHANNEL) ? 16u : 0u) |
        ((DW_GDMA.ch[CSI_RX_CHANNEL].int_sig_ena0.val & CSI_DMA_WRITABLE_SIGNALS) ? 32u : 0u) |
        ((DW_GDMA.ch[CSI_RX_CHANNEL].int_st_ena0.val & CSI_DMA_WRITABLE_EVENTS) ? 64u : 0u);
}
bool nih_csi_dma_retained_ready(void) { return nih_csi_dma_retained_flags() == 0; }

/* Called only after exclusive lease, register configuration and pre-DMA cache
 * handoff. The consumer's IRQ must not be active; status is polled. */
bool nih_csi_dma_arm(csi_rx *rx) {
    if (!rx || rx->state != CSI_RX_IDLE || !DW_GDMA.cfg0.dmac_en || CSI_DMA_ENABLED() ||
        MIPI_CSI_BRIDGE.csi_en.csi_brg_en) return false;
    dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, CSI_RX_CHANNEL, UINT32_MAX, false);
    dw_gdma_ll_channel_enable_intr_generation(&DW_GDMA, CSI_RX_CHANNEL, CSI_DMA_EVENTS, true);
    CSI_DMA_CLEAR(UINT32_MAX);
    rx->events = 0;
    rx->state = CSI_RX_ARMED; /* retain ownership even if enable misbehaves */
    CSI_DMA_FENCE();
    CSI_DMA_ENABLE(true);
    CSI_DMA_FENCE();
    if (!CSI_DMA_ENABLED()) { rx->state = CSI_RX_PINNED; return false; }
    if (stream_configured) dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, 1, CSI_DMA_EVENTS, true);
    return true;
}
/* Sensor stays off until this call succeeds. */
bool nih_csi_dma_bridge_on(csi_rx *rx) {
    if (!rx || rx->state != CSI_RX_ARMED || !CSI_DMA_ENABLED()) return false;
    mipi_csi_brg_ll_enable(&MIPI_CSI_BRIDGE, true);
    CSI_DMA_FENCE();
    if (!MIPI_CSI_BRIDGE.csi_en.csi_brg_en) { rx->state = CSI_RX_PINNED; return false; }
    rx->state = CSI_RX_RUNNING;
    return true;
}
/* The owner passes latched controller-common faults without consuming another
 * channel's copy. Errors dominate DONE, including when both arrive together. */
uint32_t nih_csi_dma_poll(csi_rx *rx, uint32_t common_fault) {
    if (!rx || (rx->state != CSI_RX_ARMED && rx->state != CSI_RX_RUNNING)) return 0;
    const uint32_t events = dw_gdma_ll_channel_get_intr_status(&DW_GDMA, CSI_RX_CHANNEL) & CSI_DMA_EVENTS;
    CSI_DMA_CLEAR(events);
    rx->events |= events;
    if (common_fault) rx->events |= CSI_DMA_ERRORS;
    return rx->events;
}
/* Live, read-only diagnostic snapshots, only while CSI and DMA are owned.
 * PHY and DMA status are samples; zero does not prove absence of activity. */
uint32_t nih_csi_dma_observe(uint32_t kind) {
    switch (kind) {
    case 0: return MIPI_CSI_HOST.phy_rx.val;
    case 1: return MIPI_CSI_BRIDGE.int_raw.val;
    case 2: return DW_GDMA.ch[CSI_RX_CHANNEL].status0.cmpltd_blk_tfr_size;
    case 3: return dw_gdma_ll_channel_get_fifo_remain(&DW_GDMA, CSI_RX_CHANNEL);
    case 4: return dw_gdma_ll_channel_get_intr_status(&DW_GDMA, CSI_RX_CHANNEL);
    case 5: return DW_GDMA.ch[CSI_RX_CHANNEL].int_sig_ena0.val;
    case 6: return DW_GDMA.ch[CSI_RX_CHANNEL].int_st_ena0.val;
    case 7: return DW_GDMA.chen0.val;
    case 8: return stop_status_before_clear;
    case 9: return DW_GDMA.ch[CSI_RX_CHANNEL].dar0.dar0;
    default: return 0;
    }
}
/* Call after attempting sensor stream-off. Returns false and pins on any
 * uncertain stop; no buffer may be reused until separate cache/IRQ checks. */
bool nih_csi_dma_stop(csi_rx *rx) {
    if (!rx || (rx->state != CSI_RX_ARMED && rx->state != CSI_RX_RUNNING && rx->state != CSI_RX_PINNED)) return false;
    const bool was_pinned = rx->state == CSI_RX_PINNED;
    mipi_csi_brg_ll_enable(&MIPI_CSI_BRIDGE, false);
    dw_gdma_ll_channel_enable_intr_propagation(&DW_GDMA, CSI_RX_CHANNEL, UINT32_MAX, false);
    CSI_DMA_ENABLE(false);
    CSI_DMA_FENCE();
    for (uint32_t poll = 0; poll < 100000; ++poll) {
        if (!CSI_DMA_ENABLED() && !MIPI_CSI_BRIDGE.csi_en.csi_brg_en) {
            stop_status_before_clear = dw_gdma_ll_channel_get_intr_status(&DW_GDMA, CSI_RX_CHANNEL);
            rx->events |= stop_status_before_clear & CSI_DMA_EVENTS;
            CSI_DMA_CLEAR(UINT32_MAX);
            /* Leave status generation enabled for a bounded diagnostic window. */
            rx->state = was_pinned ? CSI_RX_PINNED : CSI_RX_STOPPED;
            return !was_pinned;
        }
    }
    rx->state = CSI_RX_PINNED;
    return false;
}

/* Observation only: status stays latched until window_finish. No buffer reuse
 * follows from an empty observation window. Caller retains the domain/lease. */
bool nih_csi_dma_window_poll(csi_rx *rx, uint32_t *late) {
    if (!rx || !late || rx->state != CSI_RX_STOPPED || CSI_DMA_ENABLED() ||
        MIPI_CSI_BRIDGE.csi_en.csi_brg_en ||
        (DW_GDMA.ch[CSI_RX_CHANNEL].int_sig_ena0.val & CSI_DMA_WRITABLE_SIGNALS) ||
        (DW_GDMA.ch[CSI_RX_CHANNEL].int_st_ena0.val & CSI_DMA_WRITABLE_EVENTS) != CSI_DMA_WRITABLE_EVENTS) return false;
    *late |= dw_gdma_ll_channel_get_intr_status(&DW_GDMA, CSI_RX_CHANNEL) & CSI_DMA_EVENTS;
    return true;
}
uint32_t nih_csi_dma_window_finish(void) {
    uint32_t late = dw_gdma_ll_channel_get_intr_status(&DW_GDMA, CSI_RX_CHANNEL) & CSI_DMA_EVENTS;
    dw_gdma_ll_channel_enable_intr_generation(&DW_GDMA, CSI_RX_CHANNEL, CSI_DMA_EVENTS, false);
    CSI_DMA_FENCE();
    late |= dw_gdma_ll_channel_get_intr_status(&DW_GDMA, CSI_RX_CHANNEL) & CSI_DMA_EVENTS;
    CSI_DMA_CLEAR(UINT32_MAX);
    return late;
}
