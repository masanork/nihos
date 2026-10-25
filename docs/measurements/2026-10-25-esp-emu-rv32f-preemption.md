# ESP-EMU opt-in RV32F preemption smoke

- Date: 2026-10-25
- Firmware commit: `acf4e0d4b53f75582a434e4c99c3522adc15c512`
- Emulator: official ESP-EMU v0.50.0, ESP32-P4 revision-3 profile
- ESP-IDF host: v5.4.4
- Platform ABI: 5; the 128-byte integer frame is unchanged

## Result

The exact committed firmware passed the existing integer preemption test and
then ran two explicitly opted-in floating workers through the same native
timer/scheduler path. Both tests accounted for 32 ticks from 30 interrupts,
including two caught-up ticks after the deliberately delayed first interrupt.

The floating test preserved `f0` through `f31` and `fcsr` in separate 132-byte
task contexts. One probe used distinct finite register patterns and RNE with
`fcsr=1`; the other used different patterns and RTZ with `fcsr=33`. Each
performed an inexact floating addition, checked every register and `fcsr`
on every loop, and retained stack canaries across timer preemptions.

```text
integer_preemption_fpu_saves=0
integer_preemption_fpu_restores=0
fpu_preemption_elapsed_ticks=32
fpu_preemption_interrupts=30
fpu_preemption_saves=30
fpu_preemption_restores=30
fpu_preemption_worker=0
fpu_register_checks=53802
fpu_preemption_worker=1
fpu_register_checks=51952
fpu_boundary_restore=ok
native_fpu_preemption=ok
timer_period_us=1000
timer_ticks=128
timer_elapsed_us=128043
timer_restoration=ok
native_timer=ok
nihos: core smoke complete
```

The integer workers performed zero FP context transfers. Floating workers
used 30 saves and 30 restores, including the transitions to and from the
bootstrap. All 132 bytes of the physical FP bank matched the pre-window
snapshot before host interrupts were restored. The subsequent IDF callback
timer also passed. The same boot passed SMP mailbox, synchronous stack switch,
and repeated native periodic-timer resource reuse checks.

## Other checks

ZLint reported zero errors and warnings across 15 Zig files. Debug and
ReleaseSafe host runs passed 24 tests, including the clean floating-return
state and raw assembly ABI layout checks. ShellCheck and RV32 compilation of
both trap and FP assembly passed. Both revision-1 physical-target and
revision-3 emulator-target ESP-IDF builds passed. The physical-target image
is 383,568 bytes (`0x5da50`), leaving 63 percent of the application partition
free.

## Boundary

This turn intentionally advanced emulator qualification without flashing the
board, following the emulator-first development policy. It does not add a
physical P4 FPU or preemption result. Existing physical evidence remains
specific to its recorded commit.

The full-bank probes are non-returning assembly workers entered from Zig,
not compiled floating-point application benchmarks. The successful test does
not qualify Quake, FP instruction coverage, arbitrary compiler workloads,
native CPU1 FP ownership, lazy first-use faults, nesting, cache-off execution,
or physical switch cost. See [ADR 0008](../adr/0008-opt-in-eager-rv32f-context.md).
