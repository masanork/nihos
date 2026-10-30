/*
 * SPDX-FileCopyrightText: 2023-2025 Espressif Systems (Shanghai) CO LTD
 *
 * SPDX-License-Identifier: Apache-2.0
 */

/*
 * Bootloader replacement for esp_cpu_configure_region_protection.
 *
 * The IDF v5.4.4 copy programs entries 0, 1, and 15 as NAPOT|RW|L. The L bit
 * locks the entry and applies those permissions to M-mode. U-mode still
 * receives R and W. Entries 0 and 1 are the highest priority, so the app
 * cannot override them. This wrapper does not call the original function.
 * Entries 0 and 1 become unlocked NAPOT regions with no R, W, or X. U-mode
 * matches them and is denied. M-mode ignores them because L is clear.
 * Leaving those bytes OFF did not deny a U-mode load of CLIC at 0x20800000:
 * that load reached the bus and the hart stopped. Entry 15 is left OFF.
 * Entry 2 stays NAPOT|RX|L for the mask ROM. The app installs an unlocked
 * NAPOT denial on entry 8 so a leftover locked entry 15 cannot grant the
 * HP peripheral window to U-mode.
 */

#include <stdint.h>
#include "sdkconfig.h"
#include "soc/soc.h"
#include "esp_cpu.h"
#include "esp_fault.h"
#include "hal/cache_ll.h"
#include "riscv/csr.h"

void bootloader_hooks_include(void)
{
}

static void esp_cpu_configure_invalid_regions(void)
{
    const unsigned PMA_NONE                            = PMA_L | PMA_EN;
    __attribute__((unused)) const unsigned PMA_RW      = PMA_L | PMA_EN | PMA_R | PMA_W;
    __attribute__((unused)) const unsigned PMA_RX      = PMA_L | PMA_EN | PMA_R | PMA_X;
    __attribute__((unused)) const unsigned PMA_RWX     = PMA_L | PMA_EN | PMA_R | PMA_W | PMA_X;

    // ROM uses some PMA entries, so we need to clear them before using them in ESP-IDF

    // 0. Gap at bottom of address space
    PMA_RESET_AND_ENTRY_SET_NAPOT(0, 0, SOC_CPU_SUBSYSTEM_LOW, PMA_NAPOT | PMA_NONE);

    // 1. Gap between CPU subsystem region & HP TCM
    PMA_RESET_AND_ENTRY_SET_TOR(1, SOC_CPU_SUBSYSTEM_HIGH, PMA_NONE);
    PMA_RESET_AND_ENTRY_SET_TOR(2, SOC_TCM_LOW, PMA_TOR | PMA_NONE);

    // 2. Gap between HP TCM and CPU Peripherals
    PMA_RESET_AND_ENTRY_SET_TOR(3, SOC_TCM_HIGH, PMA_NONE);
    PMA_RESET_AND_ENTRY_SET_TOR(4, CPU_PERIPH_LOW, PMA_TOR | PMA_NONE);

    // 3. Gap between CPU Peripherals and I_Cache
    PMA_RESET_AND_ENTRY_SET_TOR(5, CPU_PERIPH_HIGH, PMA_NONE);
    PMA_RESET_AND_ENTRY_SET_TOR(6, SOC_IROM_LOW, PMA_TOR | PMA_NONE);

    // 4. Gap between I_Cache and external memory range
    PMA_RESET_AND_ENTRY_SET_NAPOT(7, SOC_DROM_HIGH, SOC_EXTRAM_LOW - SOC_DROM_HIGH, PMA_NAPOT | PMA_NONE);

    // 5. Gap between external memory and ROM
    PMA_RESET_AND_ENTRY_SET_TOR(8, SOC_EXTRAM_HIGH, PMA_NONE);
    PMA_RESET_AND_ENTRY_SET_TOR(9, SOC_IROM_MASK_LOW, PMA_TOR | PMA_NONE);

    // 6. Gap between ROM and internal memory
    PMA_RESET_AND_ENTRY_SET_TOR(10, SOC_IROM_MASK_HIGH, PMA_NONE);
    PMA_RESET_AND_ENTRY_SET_TOR(11, SOC_IRAM_LOW, PMA_TOR | PMA_NONE);

    // 7. Gap between internal memory and HP peripherals
    PMA_RESET_AND_ENTRY_SET_NAPOT(12, SOC_DRAM_HIGH, SOC_PERIPHERAL_LOW - SOC_DRAM_HIGH, PMA_NAPOT | PMA_NONE);

    // 8. Special case - This whitelists the External flash/RAM, HP ROM and HP L2MEM regions and make them cacheable.
    // At the startup, this is done using PMA entry 15 by the ROM code.
    PMA_RESET_AND_ENTRY_SET_NAPOT(13, SOC_IROM_LOW, SOC_PERIPHERAL_LOW - SOC_IROM_LOW, PMA_NAPOT | PMA_RWX);

    // 9. Gap between Uncacheable L2 Mem and end of address space
    PMA_RESET_AND_ENTRY_SET_TOR(14, CACHE_LL_L2MEM_NON_CACHE_ADDR(SOC_DRAM_HIGH), PMA_NONE);
    PMA_RESET_AND_ENTRY_SET_TOR(15, UINT32_MAX, PMA_TOR | PMA_NONE);
}

void __wrap_esp_cpu_configure_region_protection(void)
{
    const unsigned NONE = PMP_L;
    const unsigned RWX = PMP_L | PMP_R | PMP_W | PMP_X;

    esp_cpu_configure_invalid_regions();

    /* Entries 0 and 1 used to be NAPOT|RW|L. PMP_NAPOT is the A field only
     * (0x18): no R, W, X, or L. RESET first because SET only ORs cfg bits.
     * M-mode does not need a matching entry for an access to succeed. */
    const uint32_t pmpaddr0 = PMPADDR_NAPOT(SOC_CPU_SUBSYSTEM_LOW, SOC_CPU_SUBSYSTEM_HIGH);
    PMP_ENTRY_CFG_RESET(0);
    PMP_ENTRY_SET(0, pmpaddr0, PMP_NAPOT);
    _Static_assert(SOC_CPU_SUBSYSTEM_LOW < SOC_CPU_SUBSYSTEM_HIGH, "Invalid CPU subsystem region");
    _Static_assert((PMP_NAPOT & (PMP_L | PMP_R | PMP_W | PMP_X)) == 0, "denial must not grant or lock");

    const uint32_t pmpaddr1 = PMPADDR_NAPOT(CPU_PERIPH_LOW, CPU_PERIPH_HIGH);
    PMP_ENTRY_CFG_RESET(1);
    PMP_ENTRY_SET(1, pmpaddr1, PMP_NAPOT);
    _Static_assert(CPU_PERIPH_LOW < CPU_PERIPH_HIGH, "Invalid CPU peripheral region");

    // 3. I/D-ROM. This stays locked and executable.
    const uint32_t pmpaddr2 = PMPADDR_NAPOT(SOC_IROM_MASK_LOW, SOC_IROM_MASK_HIGH);
    PMP_ENTRY_SET(2, pmpaddr2, PMP_NAPOT | PMP_L | PMP_R | PMP_X);
    _Static_assert(SOC_IROM_MASK_LOW < SOC_IROM_MASK_HIGH, "Invalid I/D-ROM region");

    if (esp_cpu_dbgr_is_attached()) {
        // Anti-FI check that cpu is really in ocd mode
        ESP_FAULT_ASSERT(esp_cpu_dbgr_is_attached());

        // 4. IRAM and DRAM
        PMP_ENTRY_SET(3, SOC_IRAM_LOW, NONE);
        PMP_ENTRY_SET(4, SOC_IRAM_HIGH, PMP_TOR | RWX);
        _Static_assert(SOC_IRAM_LOW < SOC_IRAM_HIGH, "Invalid RAM region");
    } else {
        // 4. IRAM and DRAM. Entry 3 stays OFF and holds the TOR bottom.
        // PMP_ENTRY_SET only sets cfg bits, so clear a ROM leftover first.
        PMP_ENTRY_CFG_RESET(3);
        PMP_ENTRY_SET(3, SOC_IRAM_LOW, 0);
        PMP_ENTRY_SET(4, SOC_IRAM_HIGH, PMP_TOR | PMP_R | PMP_W | PMP_X);
        _Static_assert(SOC_IRAM_LOW < SOC_IRAM_HIGH, "Invalid RAM region");
    }

    // 5. I_Cache / D_Cache (flash), unlocked.
    const uint32_t pmpaddr6 = PMPADDR_NAPOT(SOC_IROM_LOW, SOC_IROM_HIGH);
    PMP_ENTRY_SET(6, pmpaddr6, PMP_NAPOT | PMP_R | PMP_X);
    _Static_assert(SOC_IROM_LOW < SOC_IROM_HIGH, "Invalid I/D_Cache region");

    // 6. LP memory, unlocked.
    const uint32_t pmpaddr11 = PMPADDR_NAPOT(SOC_RTC_IRAM_LOW, SOC_RTC_IRAM_HIGH);
    PMP_ENTRY_SET(11, pmpaddr11, PMP_NAPOT | PMP_R | PMP_W | PMP_X);
    _Static_assert(SOC_RTC_IRAM_LOW < SOC_RTC_IRAM_HIGH, "Invalid RTC IRAM region");

    /* Entry 15 used to be NAPOT|RW|L over 0x50000000..0x50100000. */
    PMP_ENTRY_CFG_RESET(15);
}
