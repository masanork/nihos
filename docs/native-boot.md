# Native Zig boot on ESP32-P4

This is the first independent native boot fixture. The stock ROM and
second-stage loader hand off to Zig/assembly code in internal SRAM, with no
ESP-IDF application runtime or FreeRTOS link. Both harts keep running under
nihOS-owned trap and timer handling. Each now runs the shared task runtime,
including timer preemption of two busy tasks and sleep/exit/reap/slot reuse.
After that fixture, both owners exchange 64 event notifications in each
direction while using WFI with periodic alarms disarmed.
The existing ESP-IDF display backend is still a separate implementation.

See [ADR 0018](adr/0018-independent-native-boot.md) for boot constraints and
[ADR 0019](adr/0019-permanent-native-task-owners.md) for the scheduler wiring.
Native inbox/IPI ownership and WFI qualification are described in
[ADR 0020](adr/0020-native-ipi-and-interrupt-wait.md).
Opt-in FP ownership and its integer regression mode are described in
[ADR 0021](adr/0021-native-opt-in-floating-contexts.md).
Compiler-generated Zig/C single-precision tasks and the ILP32F boundary are
covered by [ADR 0022](adr/0022-compiled-fp-and-c-boundary.md).
Owner-local SRAM allocation and its PSRAM boundary are described in
[ADR 0023](adr/0023-owner-local-native-sram.md).
Read-only native PSRAM command discovery is described in
[ADR 0024](adr/0024-bounded-native-psram-discovery.md).
Supply startup and command-data qualification are described in
[ADR 0025](adr/0025-native-psram-supply-and-command-data.md).

## Build and emulated execution

Install ESP-IDF **v5.4.4** and its ESP32-P4 tools. Set `NIHOS_IDF_PATH` if it
is not already in `IDF_PATH` or `$HOME/esp32/esp-idf-v5.4.4`. Zig 0.17.0 and
ESP-EMU 0.50.0 are checksum-verified by the existing bootstrap scripts.

```sh
sh tools/run-native-smoke.sh
sh tools/run-native-smoke.sh floating
sh tools/run-native-smoke.sh compiled
sh tools/run-native-smoke.sh integer 32M
sh tools/run-native-smoke.sh compiled 32M
```

This builds only the stock loader and partition table with IDF. Zig links
the native app separately, the image audit runs, and ESP-EMU boots with
`--psram-size 0`. Outputs live under `build/native-emulator/`:

- `nihos-native.elf`, `nihos-native.bin`, `nihos-native-flash.bin`
- `image-audit.json`: sections, ROM boundary, sizes and artifact digests
- `emulator.log`, `smoke-report.json`: 300 rounds, task evidence and IPI/idle results

Floating-mode outputs use `build/native-emulator-floating/`. The default
integer mode requires zero FP trap copies. Floating mode adds opted-in banks
and validates f0..f31/fcsr across timer preemption, task calls and a running
task's self-IPI. Each task starts with a checked zero bank, and all FP banks
are retired before the integer bootstraps confirm final FS=Off.

Compiled-mode outputs use `build/native-emulator-compiled/`. This mode uses
ILP32F for scalar float arguments/results and C-to-Zig callbacks, checks
calculation bits against an integer oracle, and requires timer captures of
the generated task code. The direct two-float structure ABI did not agree
in this pinned toolchain; this fixture uses a pointer adapter in C instead.

The report also requires three task checkpoints per hart: both busy tasks
must keep progressing under timer preemption, and both lifecycle generations
must finish sleeping, exit and be reaped. Dispatch checks interrupt/task
stack sentinels, frame bounds, and elapsed-time accounting. These checks do
not provide memory protection between tasks.

The final marker is `NIHOS_NATIVE_FP_PASS`. Each owner must show 64
ordered message deliveries, 64 wakes from a registered event wait, at least
64 IPI captures of the parked bootstrap, a running-task self-IPI, and unchanged timer IRQ counts
during the IPI interval. One arrival per hart is deliberately made pending
before WFI with MIE clear. The earlier soak marker alone cannot pass this
workflow. These observations do not measure physical power savings.

The linker now assigns the unused SRAM tail to a NOBITS `.heap` section.
CPU0 splits it into two guarded arenas before releasing CPU1. Native
allocation selects the current hart's arena and masks local interrupts only
for the cursor update. It has no shared lock, fallback, free or reset.
Each bootstrap and both preemptible workers allocate aligned buffers;
the final `NIHOS_NATIVE_MEMORY` records check patterns, guards, disjoint
bounds and exact capacity accounting after the IPI fixture. The reports
add a `memory` array, and the image audit distinguishes static reservation
from the runtime heap span. These are boot arenas, not a general reusable
heap. No external memory is registered.

Before CPU1 release, Zig now reads the PSRAM identity through MSPI3 with
bounded polling and a repeated-read check. `NIHOS_NATIVE_PSRAM` reports the
mode-register capacity while requiring zero mapped/allocatable bytes. This
is an emulated command fixture. The only ROM
calls remain console output and CPU1 entry publication.

The native path now programs and reads back LDO channel 2 for 1.8 V, using
complete factory trim fields when present and nominal settings otherwise.
It leases CPU0's stopped timer for a bounded 1 ms boot settling wait and
returns it with a reset scheduler deadline. A detected die receives verified
x8/fixed-latency mode settings, followed by two complementary write/read
passes over 22–26 address-derived samples spanning its address lines and
final word. `NIHOS_NATIVE_PSRAM_SUPPLY` and `NIHOS_NATIVE_PSRAM_IO` report
these results. An absent die receives no mode or data writes. All CPU
access still uses internal SRAM; physical voltage/timing, high-speed tuning,
MMU/cache and DMA remain unqualified.

The optional second smoke argument selects `0`, `4M`, `8M`, `16M`, `32M` or
`64M`. Nonzero results are written under `psram-SIZE/` inside that mode's
build directory. The validator requires the requested size to match the
decoded identity, then requires the complete existing 300-round run.

To compile/link only the application, without an IDF installation:

```sh
sh tools/build-native-elf.sh emulator
sh tools/build-native-elf.sh device
sh tools/build-native-elf.sh emulator build/native-emulator-floating floating
sh tools/build-native-elf.sh emulator build/native-emulator-compiled compiled
```

Normal architecture CI links and instruction-audits all three modes for both
profiles through this script. Compiled mode uses ILP32F; the other modes use
ILP32. Kernel FP instructions are rejected even in compiled mode. The tested
scalar/callback and pointer interfaces are qualified in the emulator;
arbitrary aggregates, varargs and f64 interfaces are not covered.

The manual **Native boot** workflow runs all three modes without a die and
the five populated sizes in integer mode plus compiled FP with 32 MiB,
builds the three physical images,
and retains the artifacts. It does not flash hardware.

## Physical image

```sh
sh tools/build-native.sh device
sh tools/build-native.sh device floating
sh tools/build-native.sh device compiled
```

The image is built for P4 rev1/2 CLIC threshold semantics. The emulator image
uses rev3 semantics; the two headers have disjoint revision ranges. Device
outputs are under `build/native-device/`. The app occupies the factory slot
at `0x10000`; the merged image includes loader at `0x2000` and partition table
at `0x8000` and is written at `0x0`.

Floating outputs use `build/native-device-floating/`. Modes of the same
profile share the stock loader build; build those images sequentially.

Physical qualification is pending while emulator development continues.
Do not interpret a successful device-profile build as a physical boot result.
In this fixture the console is the output; display, touch and CPU-accessible
external RAM are not initialized. Migration and a general tickless deadline policy are
not yet connected to this permanent native runtime.

The smoke has thirty-four validator regression tests, including frozen
hart/timer/task counters, missing scheduler evidence, incomplete lifecycle,
a reboot, a later failure, timer fallback during IPI-only idle and incomplete
IPI/pending-before-WFI evidence, FP accounting, wrong build mode and missing
generated-code preemption, SRAM ownership/accounting, PSRAM discovery,
supply programming and command-data accounting.
Four more tests
check instruction classification and the linker heap boundary:

```sh
python3 -m unittest discover -s tools -p 'native*_test.py'
```
