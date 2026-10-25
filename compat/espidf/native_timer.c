/* Temporary ESP-IDF resource lease for the native Zig timer/CLIC smoke.
 * The private GPTimer header is pinned to IDF v5.4.4: it is used only to
 * discover the allocated channel, not to copy or modify driver internals.
 */
#include <stddef.h>
#include <stdlib.h>
#include "driver/gptimer.h"
#include "gptimer_priv.h"
#include "hal/interrupt_clic_ll.h"
#include "riscv/rv_utils.h"
#include "nihos/platform_abi.h"

_Static_assert(sizeof(timg_hwtimer_reg_t) == 0x24, "Zig timer stride mismatch");
_Static_assert(offsetof(timg_dev_t, int_st_timers) == 0x78, "Zig timer status mismatch");
_Static_assert(offsetof(timg_dev_t, int_clr_timers) == 0x7c, "Zig timer W1C mismatch");

struct native_timer_lease {
    uint32_t group_address;
    uint32_t channel_id;
    uint32_t interrupt_id; /* CLIC cause, including the 16 internal lines. */
};

static gptimer_handle_t s_timer;
static intr_handle_t s_interrupt;
static uint32_t s_enabled_mask;
static uint32_t s_threshold;
static bool s_vectored;

static void unexpected_timer_handler(void *argument) {
    (void)argument;
    abort(); /* A timer must never run outside the native vector window. */
}

int32_t nih_espidf_native_timer_acquire(struct native_timer_lease *out) {
    if (out == NULL || xPortGetCoreID() != 0 || s_timer != NULL) {
        return NIH_STATUS_INVALID_ARGUMENT;
    }
    const gptimer_config_t config = {
        .clk_src = GPTIMER_CLK_SRC_XTAL,
        .direction = GPTIMER_COUNT_UP,
        .resolution_hz = 1000000,
    };
    if (gptimer_new_timer(&config, &s_timer) != ESP_OK) {
        return NIH_STATUS_NO_MEMORY;
    }
    int group = s_timer->group->group_id;
    int channel = s_timer->timer_id;
    int source = timer_group_periph_signals.groups[group].timer_irq_id[channel];
    /* The newly leased counter is stopped and its status was cleared by IDF.
     * Allocate with its matrix route connected; the timer starts only after
     * assembly has installed the native vector.
     */
    if (esp_intr_alloc(source, ESP_INTR_FLAG_LEVEL3,
                       unexpected_timer_handler, NULL, &s_interrupt) != ESP_OK) {
        (void)gptimer_del_timer(s_timer);
        s_timer = NULL;
        return NIH_STATUS_IO;
    }
    portENTER_CRITICAL(&s_timer->group->spinlock);
    timer_ll_enable_intr(s_timer->hal.dev, 1u << channel, true);
    portEXIT_CRITICAL(&s_timer->group->spinlock);
    *out = (struct native_timer_lease){
        .group_address = (uint32_t)(uintptr_t)s_timer->hal.dev,
        .channel_id = (uint32_t)channel,
        .interrupt_id = (uint32_t)esp_intr_get_intno(s_interrupt) + 16u,
    };
    return NIH_STATUS_OK;
}

/* Called only by assembly with MIE cleared. Other CPU0 sources remain
 * pending until the bounded native window ends; CPU1 remains untouched.
 * IDF handles the rev1 MMIO / rev3 CSR threshold difference here.
 */
void nih_espidf_native_timer_enter(void) {
    uint32_t line = (uint32_t)esp_intr_get_intno(s_interrupt);
    s_enabled_mask = rv_utils_intr_get_enabled_mask();
    rv_utils_intr_disable(UINT32_MAX);
    s_threshold = rv_utils_set_intlevel_regval(RVHAL_INTR_ENABLE_THRESH_CLIC);
    s_vectored = interrupt_clic_ll_is_vectored((int)line + 16);
    interrupt_clic_ll_set_vectored((int)line + 16, false);
    rv_utils_intr_enable(1u << line);
}

uint32_t nih_espidf_native_timer_leave(void) {
    uint32_t line = (uint32_t)esp_intr_get_intno(s_interrupt);
    rv_utils_intr_disable(UINT32_MAX);
    interrupt_clic_ll_set_vectored((int)line + 16, s_vectored);
    rv_utils_restore_intlevel_regval(s_threshold);
    rv_utils_intr_enable(s_enabled_mask);
    return rv_utils_intr_get_enabled_mask() == s_enabled_mask &&
           rv_utils_get_interrupt_threshold() == CLIC_THRESH_TO_INT(s_threshold) &&
           interrupt_clic_ll_is_vectored((int)line + 16) == s_vectored;
}

int32_t nih_espidf_native_timer_release(void) {
    if (s_timer == NULL || xPortGetCoreID() != 0) return NIH_STATUS_INVALID_ARGUMENT;
    portENTER_CRITICAL(&s_timer->group->spinlock);
    timer_ll_enable_intr(s_timer->hal.dev, 1u << s_timer->timer_id, false);
    portEXIT_CRITICAL(&s_timer->group->spinlock);
    if (esp_intr_free(s_interrupt) != ESP_OK) return NIH_STATUS_IO;
    s_interrupt = NULL;
    if (gptimer_del_timer(s_timer) != ESP_OK) return NIH_STATUS_IO;
    s_timer = NULL;
    return NIH_STATUS_OK;
}
