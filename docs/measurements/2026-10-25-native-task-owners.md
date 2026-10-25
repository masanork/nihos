# Shared task runtime on permanent native SMP owners

- Date: 2026-10-25
- Firmware implementation: `bfd36392cf725a16546d122789ced654f5214a5f`
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU v0.50.0
- [Machine-readable observations and artifact digests](2026-10-25-native-task-owners.json)
- [ADR 0019](../adr/0019-permanent-native-task-owners.md)
- Reproduce with `sh tools/run-native-smoke.sh`

## Emulator result

The revision-3 emulated ROM and stock loader booted the independently linked
native application with PSRAM absent. The permanent native trap entry used
the same 128-byte frame, task runtime, scheduler policy and scalar task-call
ABI as the hosted backend. Both harts ran their own owner instance, without
FreeRTOS application startup or a return to an IDF task.

One boot completed 300 progress rounds and three task checkpoints per hart.
Both busy tasks on each hart never voluntarily yielded or issued ECALLs;
their captured frames and increasing counters demonstrate timer preemption.

| Final observation | CPU0 | CPU1 |
| --- | ---: | ---: |
| Timer interrupts / owner elapsed ticks | 900 / 900 | 899 / 899 |
| Busy task A timer captures | 300 | 300 |
| Busy task B timer captures | 300 | 299 |
| Selected task changes | 906 | 905 |
| Task ECALLs | 12 | 12 |
| Sleep completions | 2 | 2 |
| Reaped completions | 2 | 2 |
| Busy task A progress | 17,631,151 | 17,631,088 |
| Busy task B progress | 17,631,128 | 17,630,372 |

Each lifecycle task slept three ticks, resumed after its deadline, yielded
and returned the expected exit code. Its owner reaped it on the interrupt
stack and reused its slot/stack with an incremented generation. The
replacement slept one tick and returned a different verified code. Both
old-generation wake attempts were rejected. Stack sentinels, task frame
bounds, actual interrupt-stack SP/MIE and total runtime accounting were
checked throughout the run.

## Resources and checks

Both revision profiles compiled and passed image audits. Native text was
16,892 bytes; SRAM reservation was 75,520 bytes (73.75 KiB), including two
8 KiB bootstrap stacks, two 8 KiB IRQ stacks and six 4 KiB task stacks.
This leaves 54.25 KiB in the deliberately limited 128 KiB linker region.
The app image remains 65,616 bytes because the stock loader's two Flash
metadata mappings dominate image alignment. These fixture sizes are not
production stack sizing or an application performance benchmark.

ZLint reported zero errors/warnings across 33 files. ShellCheck, the hosted
RV32 architecture contract and final native ELF links for both profiles
passed. Existing Debug/ReleaseSafe host policy tests passed from unchanged
cached inputs. Ten log-validator regression tests passed; timer-only logs,
frozen busy tasks/capture counters, missing lifecycle completion, a reboot
and incomplete execution are rejected. A failed smoke rerun removes its
previous success report before attempting the new build.

An exploratory run with 4M-cycle progress samples reached the 45-second
emulator limit shortly before round 300. It was recorded as a failed run.
The final fixture uses 2M-cycle samples and a 60-second wall-clock limit,
and passed with the final source. Sampling intervals are not wall time or
throughput guarantees. Tick-clock phase comes from the native hardware
counter, independently of the progress sampling loop.

## Remaining gates

No physical device was accessed: physical qualification is explicitly
deferred while wiring continues. Native IPI, WFI idle, FP ownership, task
migration, PSRAM, display and protection domains remain unconnected. This
record does not inherit those qualifications from the hosted backend.
Remote CI and manual native-workflow results remain separate from these
local observations.
