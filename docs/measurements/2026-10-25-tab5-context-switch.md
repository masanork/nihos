# Physical Tab5 native context-switch smoke

- Date: 2026-10-25
- Firmware commit: `9910e688af7aee32054337391112a83c22fcd220`
- Board: M5Stack Tab5, ESP32-P4 revision 1.3
- Backend: ESP-IDF v5.4.4 boot and FreeRTOS host; nihOS owns the bounded trap
  save/select/restore path
- Platform ABI: 5

## Result

The exact committed firmware switched from the ESP-IDF bootstrap task to a
separate 4 KiB Zig task stack and back through two synchronous machine-mode
`ecall` exceptions. The trap entry saved a 128-byte RV32 integer frame,
changed to a private 2 KiB CPU0 interrupt stack, called the Zig dispatcher,
and restored the selected frame with `mret`.

The Zig task observed its expected argument and yielded back to the original
frame. The boot emitted:

```text
periodic_timer=ok
native_context_switch=ok
nihos: core smoke complete
axi_gdma_copy=ok
display_refresh_millihz=65466
display_scanout=ok
display_vsync=ok
touch_sampling=ok
nihos: bootstrap complete
```

The same boot completed the 100,000-message CPU0/CPU1 mailbox, observed 128
ticks from the 1,000 us timer in 128,241 us, copied all four internal/PSRAM
DMA paths, and measured 60 display-vsync samples in 916,497 us.

## Hardware-only failure found

The preceding `c86e6f5` implementation passed ESP-EMU but faulted on the
physical P4 as soon as the trap entry changed `sp` to its private interrupt
stack. The panic reported `Stack protection fault`: maskable interrupts were
off, but the P4 hardware stack monitor still enforced the FreeRTOS task's
bounds.

The repaired helper explicitly includes ESP-IDF's generated `sdkconfig.h`,
stops the hardware stack monitor after clearing `mstatus.MIE`, performs the
bounded two-exception switch, restores the original stack, restarts the
monitor, and only then restores the caller's interrupt state. Disassembly was
checked to ensure the conditional stop/start calls are present; omitting the
generated header had previously compiled those calls out.

## Boundary

This qualifies a controlled native save/select/restore round trip on CPU0 and
physical silicon. It is not timer-driven preemption: ESP-IDF still owns boot,
the normal CLIC vector, timer allocation, FreeRTOS scheduling, and CPU1
startup. Native scheduling still requires nested-interrupt, FPU, CPU1, and
load testing.

## Per-stack guard follow-up

Exact firmware commit `5176a55a1cc22341833ca58236e9e7888e6f4133`
replaced the whole-test monitor suspension with per-stack bounds. Each trap
now stops monitoring only for the stack-pointer transition, sets bounds for
the CPU0 interrupt stack or the selected task, and restarts monitoring before
executing dispatcher or task code. The self-test also fails unless the
original FreeRTOS bounds are restored after returning.

That exact commit passed the same physical bootstrap sequence. It observed
128 timer ticks in 128,256 us, completed all DMA paths, measured display
refresh at 65.467 Hz, completed idle touch sampling, and reached
`nihos: bootstrap complete` without a stack-protection fault.
