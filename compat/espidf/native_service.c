/* Pinned IDF resource boundary for a bounded CPU1 native timer/IPI service.
 * The borrowed IPI is not remapped; IDF retains its reason array.
 */
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>
#include <stdint.h>
#include "driver/gptimer.h"
#include "gptimer_priv.h"
#include "esp_intr_alloc.h"
#include "esp_ipc.h"
#include "esp_private/crosscore_int.h"
#include "hal/crosscore_int_ll.h"
#include "hal/interrupt_clic_ll.h"
#include "riscv/rv_utils.h"
#include "soc/interrupts.h"
#include "soc/hp_system_reg.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nihos/platform_abi.h"

struct native_service_lease {
    uint32_t register_address;
    uint32_t interrupt_id;
};

struct native_service_timer_lease {
    uint32_t group_address;
    uint32_t channel_id;
    uint32_t interrupt_id;
};

static gptimer_handle_t s_timer;
static intr_handle_t s_timer_interrupt;

static struct {
    bool borrowed;
    bool active;
    bool entered;
    bool vectored;
    uint32_t cause;
    uint32_t route;
    uint32_t enabled_mask;
    uint32_t threshold;
    bool timer_vectored;
    bool timer_was_leased;
    uint32_t timer_pre_enabled_mask;
} s_service;

static void unexpected_service_timer_handler(void *argument) {
    (void)argument;
    abort(); /* The counter must only interrupt inside the native vector window. */
}

int32_t nih_espidf_native_service_timer_acquire(struct native_service_timer_lease *out) {
    if (out == NULL || xPortGetCoreID() != 1 || !s_service.borrowed ||
        s_service.active || s_service.entered || s_timer != NULL)
        return NIH_STATUS_INVALID_ARGUMENT;
    const gptimer_config_t config = {
        .clk_src = GPTIMER_CLK_SRC_XTAL,
        .direction = GPTIMER_COUNT_UP,
        .resolution_hz = 1000000,
    };
    if (gptimer_new_timer(&config, &s_timer) != ESP_OK) return NIH_STATUS_NO_MEMORY;
    const int group = s_timer->group->group_id;
    const int channel = s_timer->timer_id;
    const int source = timer_group_periph_signals.groups[group].timer_irq_id[channel];
    /* IDF allocates the source on the calling core; this lease is CPU1-only. */
    s_service.timer_pre_enabled_mask = rv_utils_intr_get_enabled_mask();
    if (esp_intr_alloc(source, ESP_INTR_FLAG_LEVEL3,
                       unexpected_service_timer_handler, NULL,
                       &s_timer_interrupt) != ESP_OK) {
        (void)gptimer_del_timer(s_timer);
        s_timer = NULL;
        return NIH_STATUS_IO;
    }
    if (esp_intr_get_cpu(s_timer_interrupt) != 1 ||
        (uint32_t)esp_intr_get_intno(s_timer_interrupt) + 16u == s_service.cause) {
        if (esp_intr_get_cpu(s_timer_interrupt) == 1) {
            const uint32_t line = (uint32_t)esp_intr_get_intno(s_timer_interrupt);
            const uint32_t line_bit = 1u << line;
            if (s_service.timer_pre_enabled_mask & line_bit)
                rv_utils_intr_enable(line_bit);
            else
                rv_utils_intr_disable(line_bit);
        }
        (void)esp_intr_free(s_timer_interrupt);
        s_timer_interrupt = NULL;
        (void)gptimer_del_timer(s_timer);
        s_timer = NULL;
        return NIH_STATUS_IO;
    }
    portENTER_CRITICAL(&s_timer->group->spinlock);
    timer_ll_enable_intr(s_timer->hal.dev, 1u << channel, true);
    portEXIT_CRITICAL(&s_timer->group->spinlock);
    s_service.timer_was_leased = true;
    *out = (struct native_service_timer_lease){
        .group_address = (uint32_t)(uintptr_t)s_timer->hal.dev,
        .channel_id = (uint32_t)channel,
        .interrupt_id = (uint32_t)esp_intr_get_intno(s_timer_interrupt) + 16u,
    };
    return NIH_STATUS_OK;
}

int32_t nih_espidf_native_service_acquire(struct native_service_lease *out) {
    if (out == NULL || xPortGetCoreID() != 1 || s_service.borrowed)
        return NIH_STATUS_INVALID_ARGUMENT;
    const uint32_t route = REG_READ(DR_REG_INTERRUPT_CORE1_BASE +
                                     4u * ETS_FROM_CPU_INTR1_SOURCE);
    const uint32_t cause = route & 0x3fu;
    if (cause < 16 || cause >= 48 || interrupt_clic_ll_get_type((int)cause) != 0 ||
        !(rv_utils_intr_get_enabled_mask() & (1u << (cause - 16u)))) return NIH_STATUS_IO;
    s_service.borrowed = true;
    s_service.active = false;
    s_service.entered = false;
    s_service.timer_was_leased = false;
    s_service.timer_pre_enabled_mask = 0;
    s_service.cause = cause;
    s_service.route = route;
    s_service.vectored = interrupt_clic_ll_is_vectored((int)cause);
    *out = (struct native_service_lease){ HP_SYSTEM_CPU_INT_FROM_CPU_1_REG, cause };
    return NIH_STATUS_OK;
}

/* Assembly calls these on CPU1 with MIE clear. Only the leased timer and IPI
 * lines remain enabled; without a timer lease this remains IPI-only. */
void nih_espidf_native_service_enter(void) {
    s_service.enabled_mask = rv_utils_intr_get_enabled_mask();
    rv_utils_intr_disable(UINT32_MAX);
    s_service.threshold = rv_utils_set_intlevel_regval(RVHAL_INTR_ENABLE_THRESH_CLIC);
    interrupt_clic_ll_set_vectored((int)s_service.cause, false);
    uint32_t native_mask = 1u << (s_service.cause - 16u);
    if (s_timer != NULL) {
        const uint32_t timer_cause = (uint32_t)esp_intr_get_intno(s_timer_interrupt) + 16u;
        s_service.timer_vectored = interrupt_clic_ll_is_vectored((int)timer_cause);
        interrupt_clic_ll_set_vectored((int)timer_cause, false);
        native_mask |= 1u << (timer_cause - 16u);
    }
    s_service.active = true;
    s_service.entered = true;
    rv_utils_intr_enable(native_mask);
}

uint32_t nih_espidf_native_service_leave(void) {
    rv_utils_intr_disable(UINT32_MAX);
    interrupt_clic_ll_set_vectored((int)s_service.cause, s_service.vectored);
    if (s_timer != NULL) {
        const uint32_t timer_cause = (uint32_t)esp_intr_get_intno(s_timer_interrupt) + 16u;
        interrupt_clic_ll_set_vectored((int)timer_cause, s_service.timer_vectored);
    }
    /* mtvec is IDF's again. Preserve all retained IDF reasons by replaying. */
    crosscore_int_ll_trigger_interrupt(1);
    rv_utils_restore_intlevel_regval(s_service.threshold);
    rv_utils_intr_enable(s_service.enabled_mask);
    s_service.active = false;
    return rv_utils_intr_get_enabled_mask() == s_service.enabled_mask &&
           rv_utils_get_interrupt_threshold() == CLIC_THRESH_TO_INT(s_service.threshold) &&
           interrupt_clic_ll_is_vectored((int)s_service.cause) == s_service.vectored &&
           (s_timer == NULL || interrupt_clic_ll_is_vectored(
               esp_intr_get_intno(s_timer_interrupt) + 16) == s_service.timer_vectored);
}

/* Caller stops the raw-MMIO counter before leaving the native window. */
int32_t nih_espidf_native_service_timer_release(void) {
    if (xPortGetCoreID() != 1 || !s_service.borrowed || s_service.active || s_timer == NULL)
        return NIH_STATUS_INVALID_ARGUMENT;
    if (s_timer_interrupt != NULL && esp_intr_get_cpu(s_timer_interrupt) != 1)
        return NIH_STATUS_INVALID_ARGUMENT;
    const uint32_t channel = (uint32_t)s_timer->timer_id;
    const uint32_t event = 1u << channel;
    portENTER_CRITICAL(&s_timer->group->spinlock);
    const bool running = s_timer->hal.dev->hw_timer[channel].config.tx_en != 0;
    const uint32_t pending = timer_ll_get_intr_status(s_timer->hal.dev) & event;
    if (running || pending != 0) {
        portEXIT_CRITICAL(&s_timer->group->spinlock);
        return NIH_STATUS_BUSY;
    }
    timer_ll_enable_intr(s_timer->hal.dev, event, false);
    portEXIT_CRITICAL(&s_timer->group->spinlock);
    if (s_timer_interrupt != NULL) {
        const uint32_t line = (uint32_t)esp_intr_get_intno(s_timer_interrupt);
        const uint32_t line_bit = 1u << line;
        /* intr_free disconnects the peripheral matrix route but leaves the
         * CPU CLIC enable bit alone. Restore that owned bit to its pre-lease
         * value before dropping the handle; preserve every other CPU line. */
        if (s_service.timer_pre_enabled_mask & line_bit)
            rv_utils_intr_enable(line_bit);
        else
            rv_utils_intr_disable(line_bit);
        if (esp_intr_free(s_timer_interrupt) != ESP_OK) return NIH_STATUS_IO;
        s_timer_interrupt = NULL;
    }
    if (gptimer_del_timer(s_timer) != ESP_OK) return NIH_STATUS_IO;
    s_timer = NULL;
    return NIH_STATUS_OK;
}

int32_t nih_espidf_native_service_release(void) {
    if (xPortGetCoreID() != 1 || !s_service.borrowed || s_service.active || s_timer != NULL)
        return NIH_STATUS_INVALID_ARGUMENT;
    const uint32_t expected_enabled_mask =
        s_service.entered && s_service.timer_was_leased
            ? s_service.timer_pre_enabled_mask
            : s_service.enabled_mask;
    const bool restored =
        REG_READ(DR_REG_INTERRUPT_CORE1_BASE + 4u * ETS_FROM_CPU_INTR1_SOURCE) == s_service.route &&
        interrupt_clic_ll_is_vectored((int)s_service.cause) == s_service.vectored &&
        (!s_service.entered || rv_utils_intr_get_enabled_mask() == expected_enabled_mask);
    s_service.borrowed = false;
    return restored ? NIH_STATUS_OK : NIH_STATUS_IO;
}

/* Test-only reason submission from CPU0's quiescent bootstrap prepare hook. */
void nih_espidf_native_service_probe_yield(void) {
    esp_crosscore_int_send_yield(1);
}

static void service_host_probe(void *argument) {
    atomic_store_explicit((_Atomic uint32_t *)argument, (uint32_t)xPortGetCoreID(), memory_order_release);
}

/* Called only after both native windows return to normal IDF task context. */
int32_t nih_espidf_native_service_verify_host(void) {
    _Atomic uint32_t observed = UINT32_MAX;
    if (esp_ipc_call_blocking(1, service_host_probe, &observed) != ESP_OK) return NIH_STATUS_IO;
    return atomic_load_explicit(&observed, memory_order_acquire) == 1 ? NIH_STATUS_OK : NIH_STATUS_IO;
}
