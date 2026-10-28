/* CPU0 foreground-only adapter. Base linker symbols, never app addresses,
 * define the allocatable DMA-capable SRAM. ISR code cannot allocate. */
#if NIH_NATIVE_CARD_READ
#define NIH_SRAM_FOREGROUND __attribute__((section(".flash.text.card")))
#endif
#include "sram_pool.h"
extern uint8_t __service_sram0_start, __service_sram0_end;
extern uint8_t __service_sram1_start, __service_sram1_end;
static nih_sram_pool service_sram;
static NIH_SRAM_FOREGROUND uint32_t base_sram_lock(void) {
    uint32_t status;
    __asm__ volatile("csrrci %0,mstatus,8" : "=r"(status) :: "memory");
    return status;
}
static NIH_SRAM_FOREGROUND void base_sram_unlock(uint32_t status) {
    if (status & 8u) __asm__ volatile("csrsi mstatus,8" ::: "memory");
}
static NIH_SRAM_FOREGROUND bool base_sram_cpu0(void) {
    uint32_t hart;
    __asm__ volatile("csrr %0,mhartid" : "=r"(hart));
    return hart == 0;
}
NIH_SRAM_FOREGROUND bool nih_base_sram_take(uint32_t owner, uint32_t minimum, uint32_t maximum, nih_sram_lease *out) {
    if (!base_sram_cpu0() || !out) return false;
    const uint32_t status = base_sram_lock();
    if (!service_sram.ready) {
        const nih_sram_region regions[2] = {
            {(uint32_t)(uintptr_t)&__service_sram0_start, (uint32_t)((uintptr_t)&__service_sram0_end - (uintptr_t)&__service_sram0_start)},
            {(uint32_t)(uintptr_t)&__service_sram1_start, (uint32_t)((uintptr_t)&__service_sram1_end - (uintptr_t)&__service_sram1_start)},
        };
        if (!nih_sram_pool_init(&service_sram, regions)) { base_sram_unlock(status); return false; }
    }
    const bool ok = nih_sram_pool_take(&service_sram, owner, minimum, maximum, out);
    base_sram_unlock(status); return ok;
}
NIH_SRAM_FOREGROUND bool nih_base_sram_release(const nih_sram_lease *lease) {
    if (!base_sram_cpu0() || !lease) return false;
    const uint32_t status = base_sram_lock();
    const bool ok = nih_sram_pool_release(&service_sram, lease);
    base_sram_unlock(status); return ok;
}
