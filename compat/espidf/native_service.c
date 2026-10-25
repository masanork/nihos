/* Pinned IDF resource boundary for a bounded CPU1 native IPI service.
 * No interrupt is reallocated or remapped; IDF retains its reason array.
 */
#include <stdatomic.h>
#include <stdint.h>
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

static struct {
    bool borrowed;
    bool active;
    bool entered;
    bool vectored;
    uint32_t cause;
    uint32_t route;
    uint32_t enabled_mask;
    uint32_t threshold;
} s_service;

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
    s_service.cause = cause;
    s_service.route = route;
    s_service.vectored = interrupt_clic_ll_is_vectored((int)cause);
    *out = (struct native_service_lease){ HP_SYSTEM_CPU_INT_FROM_CPU_1_REG, cause };
    return NIH_STATUS_OK;
}

/* Assembly calls these on CPU1 with MIE clear. Only its IPI remains enabled. */
void nih_espidf_native_service_enter(void) {
    s_service.enabled_mask = rv_utils_intr_get_enabled_mask();
    rv_utils_intr_disable(UINT32_MAX);
    s_service.threshold = rv_utils_set_intlevel_regval(RVHAL_INTR_ENABLE_THRESH_CLIC);
    interrupt_clic_ll_set_vectored((int)s_service.cause, false);
    s_service.active = true;
    s_service.entered = true;
    rv_utils_intr_enable(1u << (s_service.cause - 16u));
}

uint32_t nih_espidf_native_service_leave(void) {
    rv_utils_intr_disable(UINT32_MAX);
    interrupt_clic_ll_set_vectored((int)s_service.cause, s_service.vectored);
    /* mtvec is IDF's again. Preserve all retained IDF reasons by replaying. */
    crosscore_int_ll_trigger_interrupt(1);
    rv_utils_restore_intlevel_regval(s_service.threshold);
    rv_utils_intr_enable(s_service.enabled_mask);
    s_service.active = false;
    return rv_utils_intr_get_enabled_mask() == s_service.enabled_mask &&
           rv_utils_get_interrupt_threshold() == CLIC_THRESH_TO_INT(s_service.threshold) &&
           interrupt_clic_ll_is_vectored((int)s_service.cause) == s_service.vectored;
}

int32_t nih_espidf_native_service_release(void) {
    if (xPortGetCoreID() != 1 || !s_service.borrowed || s_service.active)
        return NIH_STATUS_INVALID_ARGUMENT;
    const bool restored =
        REG_READ(DR_REG_INTERRUPT_CORE1_BASE + 4u * ETS_FROM_CPU_INTR1_SOURCE) == s_service.route &&
        interrupt_clic_ll_is_vectored((int)s_service.cause) == s_service.vectored &&
        (!s_service.entered || rv_utils_intr_get_enabled_mask() == s_service.enabled_mask);
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
