# ADR 0018: Boot a separate native Zig application without FreeRTOS

- Status: accepted; emulator qualified, physical qualification pending
- Date: 2026-10-25

## Decision

Add an independent native application beside the existing ESP-IDF bring-up
backend. The ROM and stock ESP-IDF v5.4.4 second-stage loader remain. After
the loader jumps to `nih_native_start`, nihOS owns both harts permanently:
its own CRT, stacks, BSS initialization, machine trap entry, interrupt routing,
Timer Group channels, and CPU1 release. No ESP-IDF application archive, C
runtime, FreeRTOS entry, scheduler, heap, BSP, or PSRAM driver is linked into
this application. The bootloader itself continues to contain vendor C code.

The initial native image is a boot fixture, not the complete nihOS kernel.
Each hart executes one continuous integer loop. It does not yet run the
existing scheduler's task set or native service protocol. Existing bounded
ESP-IDF scenarios remain useful as driver and scheduler comparison fixtures.

```text
ROM -> stock second-stage loader -> nih_native_start (SRAM)
                                      |-- CPU0 CRT, trap, timer, loop
                                      `-- direct CPU1 release
                                            `-- own stack, trap, timer, loop
```

## Keep the initial hardware surface small

All executable code, ordinary constants, initialized data, BSS and stacks live
in `0x4ff00000..0x4ff20000`, below the rev1 bootloader and ROM CPU1 stack.
Each hart has an 8 KiB stack. The native app does not touch PSRAM, external
Flash contents, display, touch, DMA, or persistent files. It inherits the
bootloader's initial clock tree and ROM console configuration. It disables
the inherited LP watchdog and the reset Timer Group's flash-boot watchdog;
a native watchdog service remains future work.

Two ROM ABI addresses provide console output and the CPU1 entry mailbox.
CPU1 clock/reset/unstall, interrupt matrix and timer register operations are
independent Zig code based on the pinned official definitions. Shared timer
clock and reset registers are set up by CPU0 before CPU1 starts; thereafter
each hart owns its channel and its local CLIC controller. The existing pure
Zig `timer_group.zig` supplies per-channel operations in both backends.

The stock P4 loader asserts that two external mapped segments exist. Keep a
256-byte application descriptor and a four-byte compatibility marker in
separate Flash mappings. Neither holds native instructions or ordinary
runtime data. This requirement pads the app image to about 64 KiB despite
the much smaller SRAM payload; it is boot format overhead, not resident SRAM.
Removing the Flash metadata requires changing the loader, which is outside
this first milestone.

## Trap and concurrency contract

`mtvec` points at a 64-byte-aligned, non-vectored CLIC entry. The trap saves
integer caller-clobbered registers and active `mcause`/`mstatus`; the C ABI
preserves callee-saved registers. Dispatch is integer-only and non-nested on
the hart's private stack. `mret` restores the active cause as required by the
P4 CLIC. ECALL advances PC by four bytes; timer interrupts resume the original
PC. Unexpected traps print their cause, PC and hart, then stop.

TG0.T0 and TG0.T1 use the 40 MHz XTAL divided by 40, with 10,000-tick periodic
alarms. Each routes to its owner's CLIC input 16. Rev1/2 threshold MMIO and
rev3 threshold CSR are selected at build time, with corresponding chip
revision bounds in the image header. CPU1 release waits for unstall with a
bounded failure path before enabling the clock, releasing reset and writing
the ROM entry mailbox.

Per-hart progress, exception and timer counters use release/acquire atomics
in shared internal SRAM. CPU0 exclusively prints normal progress. There is
no task migration, FPU ownership, WFI idle, nested trap, memory protection,
or SMP scheduler claim in this fixture. A fault on the other hart can still
interleave diagnostic output; robust panic coordination comes later.

## Qualification and next stages

`build-native.sh` builds the loader separately and links the app directly
with Zig. Image auditing enforces the SRAM/ROM/metadata boundary, absence of
undefined symbols, native entry, stack layout, ELF digest in the descriptor,
and image digest. This structural audit is not a memory-safety proof.

`run-native-smoke.sh` boots from the actual emulated ROM with no external
RAM. A successful run requires a single boot, CRT/ECALL success, 300 progress
rounds, increasing hart and timer counters, three execution checkpoints and
the final marker. A lone marker or an emulator exit code is insufficient.
Counters describe execution progress rather than a throughput benchmark or
a specified wall-clock duration. Native CI is manually dispatched, so this
additional SDK/emulator build does not run on every documentation change.

Next: qualify the rev1 image on an exclusively available physical Tab5;
attach the existing scheduler/context-switch implementation to this permanent
vector owner; add native IPI/idle; then bring up clock/cache/PSRAM and one
display path at a time. Existing host policy tests and hosted driver fixtures
remain separate evidence throughout.

## Primary references

- [ESP-IDF v5.4.4 startup flow](https://docs.espressif.com/projects/esp-idf/en/v5.4.4/esp32p4/api-guides/startup.html)
- [Official CPU startup and CPU1 release](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_system/port/cpu_start.c)
- [Official P4 bootloader memory layout](https://github.com/espressif/esp-idf/blob/v5.4.4/components/bootloader/subproject/main/ld/esp32p4/bootloader.ld)
- [Official loader mapped-segment requirement](https://github.com/espressif/esp-idf/blob/v5.4.4/components/bootloader_support/src/bootloader_utility.c)
- [Official application descriptor format](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_app_format/include/esp_app_desc.h)
- [Official rev1 clock/reset register definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/soc/esp32p4/register/hw_ver1/soc/hp_sys_clkrst_reg.h)
- [Official timer clock and channel configuration](https://github.com/espressif/esp-idf/blob/v5.4.4/components/hal/esp32p4/include/hal/timer_ll.h)
- [Official CLIC revision differences](https://github.com/espressif/esp-idf/blob/v5.4.4/components/riscv/include/esp_private/interrupt_clic.h)
- [Official ROM symbol addresses](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_rom/esp32p4/ld/esp32p4.rom.ld)
