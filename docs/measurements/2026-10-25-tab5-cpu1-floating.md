# CPU1 floating contexts in ESP-EMU and on physical Tab5

- Date: 2026-10-25
- Firmware commit: `26c4bea821b326771a0c952aed01cda6b24210a0`
- Host SDK: ESP-IDF v5.4.4; platform ABI 5
- Physical board: M5Stack Tab5, ESP32-P4 revision 1.3
- Emulator: ESP-EMU v0.50.0, ESP32-P4 revision-3 profile
- Physical image: 428,736 bytes (`0x68ac0`)
- Application SHA-256: `37e8d1854e6164f49a9861ff99ef7b0e17e3374b3edd1c131c8d111451c96c4a`
- [Machine-readable emulator and three-boot results](2026-10-25-tab5-cpu1-floating.json)

## Result

The exact committed implementation passed ESP-EMU core smoke, then three
consecutive full physical boots after an esptool-verified application write.
Each physical run used a USB Serial/JTAG RTS reset with power connected and
reached `nihos: bootstrap complete`, including the subsequent DMA, display,
vsync, and idle touch checks. The serial port was released afterward.

Both CPU1 tasks opted into separate 132-byte FP contexts. A private
non-returning assembly wrapper seeded all registers, then ran the existing
integer-only service/observer callbacks with that bank live. Each task used
different raw patterns in `f0` through `f30`, computed `f31` by an inexact
addition, and retained its own rounding mode and NX flag: service `fcsr=1`
(RNE), observer `fcsr=33` (RTZ). Read-only checks verified the full bank
throughout the task and again after its callback returned, before EXIT.

| Observation | ESP-EMU | Physical boot 1 | Boot 2 | Boot 3 |
| --- | ---: | ---: | ---: | ---: |
| CPU1 FP saves / restores | 496 / 496 | 496 / 496 | 496 / 496 | 496 / 496 |
| Task-call / timer / IPI traps | 392 / 36 / 68 | 392 / 36 / 68 | 392 / 36 / 68 | 392 / 36 / 68 |
| Service / observer full-bank checks | 389 / 1,021 | 389 / 652 | 389 / 652 | 389 / 652 |
| Service / observer timer captures | 0 / 5 | 0 / 5 | 0 / 5 | 0 / 5 |
| Service / observer IPI captures | 33 / 3 | 1 / 3 | 1 / 3 | 1 / 3 |
| Service / observer task calls | 261 / 131 | 261 / 131 | 261 / 131 | 261 / 131 |
| Initial / final IDF FS state | Off / Off | Off / Off | Off / Off | Off / Off |
| Elapsed / summed runtime ticks | 38 / 38 | 38 / 38 | 38 / 38 | 38 / 38 |
| Sleep start / deadline / resumed | 3 / 8 / 8 | 3 / 8 / 8 | 3 / 8 / 8 | 3 / 8 / 8 |
| Duplex messages / validated payloads | 64 / 64 | 64 / 64 | 64 / 64 | 64 / 64 |
| Actual CPU1 slot changes | 201 | 265 | 265 | 265 |

Save and restore totals matched every handled CPU1 native trap:
`496 = 392 + 36 + 68`. There was one save and one restore per trap, including
bootstrap transitions. Per-task capture counts distinguish worker execution
from idle; remaining IPI deliveries can capture the bootstrap. Differences
between emulator and silicon counters are functional scheduling observations,
not a performance comparison.

The service slept for five accepted CPU1 scheduler ticks. Its peer checked FP
state inside a loop with no ECALL, yield, or clock query. CPU1's timer woke
the service, which resumed at tick 8. A readiness handshake also required an
IPI capture after the observer entered that loop. Both tasks subsequently
checked their banks around ECALL waits, notifications, and yields while the
64-pair duplex protocol ran. The service had no timer captures in these runs;
the observer supplies the asynchronous timer proof, while both banks are
exercised by task calls and IPIs.

## IDF preservation and integer regression

The IDF bootstrap had FS=Off on entry. The native owner nevertheless kept a
nonnull bootstrap context so the first trap saved the physical bank before
any dispatcher or guard helper. Final selection restored that same bootstrap
bank. With MIE clear, the finish hook checked its owner pointer, compared all
132 bytes against the pre-task snapshot, and verified FS was still Off before
clearing the native pointers and returning to IDF. All runs reported
`cpu1_fp_boundary_restored=1` and `cpu1_fp_both_hosts_restored=1`.

Both tasks exited with their expected codes and were reaped; stale-handle
and replacement-generation checks still passed. Normal IDF host probes ran
after restoration. The final IDF timer delivered 128 callbacks per physical
boot in 128,086 us. The older untimed and timed integer CPU1 scenarios each
reported exactly zero FP saves and restores. This is zero bank-copy work in
those modes, not a claim that FP opt-in branches have no instruction cost.

## Validation and resources

Debug and ReleaseSafe each passed the existing 51 host tests. ZLint reported
zero errors and warnings across 31 Zig files; formatting, ShellCheck, RV32
architecture compilation, the C/Zig/Rust ABI probe, and both physical and
emulator IDF builds passed. The assembly compile check now includes the shared
task-call-number header used by the probe's EXIT path.

The physical image grew by 4,800 bytes over the previously qualified integer
image, including the new fixture, counters, and console fields. It leaves
59 percent of its 1 MiB app partition free. Three 132-byte owner/task banks
and two boundary snapshots require 660 bytes; the two probe records add 40
bytes, plus scalar bookkeeping. The mode reuses the existing two fixed 4 KiB
CPU1 task stacks and interrupt stack. FP context switching does not allocate
heap storage or add a run-queue lock.

## Boundary

This qualifies CPU1 FP contexts across timer, IPI, and task-call paths under
the bounded ESP-IDF-hosted runtime. CPU0 was an integer client during this
scenario; its FP preemption fixture ran earlier in a separate window. No
simultaneous both-core FP workload, migration, nested-trap, lazy/dirty-only
transfer, compiler-generated floating-point application ABI, or performance
claim follows. The probe callbacks intentionally use integer-only code;
ordinary C ABI calls may clobber caller-saved FP registers and must not be
treated as arbitrary callbacks for this test.

USB reset repetition is not cold-power or long-duration qualification. Touch
polls observed no points; pressed input was not tested. Game/audio load,
permanent native boot/interrupt ownership, and Flash/cache-off coordination
remain separate work. See [ADR 0016](../adr/0016-cpu1-floating-contexts.md).
