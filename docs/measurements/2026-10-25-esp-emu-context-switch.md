# ESP-EMU native context-switch smoke

- Date: 2026-10-25
- Emulator: official ESP-EMU v0.50.0
- Target profile: ESP32-P4 revision 3, RV32IMAF
- ESP-IDF oracle: v5.4.4

## Result

The bootstrap temporarily disabled maskable interrupts and replaced `mtvec`
for a bounded synchronous-exception test. The first machine-mode `ecall`
saved the ESP-IDF task's 128-byte integer frame, changed to a private 2 KiB
per-core interrupt stack, and dispatched in Zig. The dispatcher selected an
initialized frame on a separate 4 KiB Zig task stack.

`mret` entered the Zig task through the nihOS task trampoline. The task
observed its expected argument, issued a second `ecall`, and the dispatcher
selected the original bootstrap frame. A second `mret` restored the original
stack and execution point. The helper then restored ESP-IDF's `mtvec` and
interrupt state and printed:

```text
native_context_switch=ok
nihos: core smoke complete
```

The earlier SMP mailbox and periodic timer smoke also passed in the same boot.

## Boundary

This executes nihOS save/select/restore assembly and a Zig dispatcher on an
emulated ESP32-P4. It is more than a compile-only layout check, but it remains
a controlled cooperative exception. ESP-IDF still owns boot, normal CLIC
vectors, the periodic timer, and FreeRTOS scheduling. Timer-driven
preemption, nested interrupts, FPU context, CPU1 switching, and physical-board
behavior remain separate qualification gates.
