# nihos

> 素のハードウェアを、色づける。

**nihos** is an experimental, small, educational operating system for the
M5Stack Tab5 and its ESP32-P4. It is intended to explore a readable Zig-first
system that uses the hardware well without hiding the important mechanisms
behind a large framework.

The project is at the design and hardware-bootstrap stage. Its
ESP-IDF-hosted Zig entry boots on a physical Tab5 and now writes the MIPI-DSI
scanout framebuffer directly and synchronizes to display refresh. nihOS does
not yet own the permanent scheduler or native device drivers. Bounded native
execution exercises CPU0 task preemption and event waits, plus an independent
CPU1 task runtime with its own timer, IPI wakeup, and WFI idle context.
Each window restores the ESP-IDF host afterward. A bounded touch ABI can also
initialize and poll the panel-matched controller.

## Name

The name is pronounced **ニホス**. It comes from the classical Japanese verb
「にほす（匂す）」—to dye or give colour—and ends naturally in `os` when its
final `u` is removed for the project name.

The older sense is visual rather than merely olfactory: to make something
take on colour or radiance. That is the intent here—to make bare hardware
expressive while keeping the machinery visible to the reader.

## Direction

- Use Zig 0.17.0 for the kernel, HAL, and native services.
- Keep C and assembly boundaries small and explicit where the vendor SDK,
  boot path, or hardware support requires them.
- Keep the platform boundary as a small handwritten C ABI so that C and Rust
  comparison implementations remain possible without leaking ESP-IDF types
  into the kernel.
- Use both ESP32-P4 cores deliberately, with measured SMP costs and benefits.
- Prefer low overhead and simple invariants over server-grade security
  machinery, while using static analysis and hardware isolation where useful.
- Treat graphics and input latency as first-class concerns; Quake near 60 FPS
  is a performance target, not a current claim.
- Keep the source readable enough to serve as an operating-systems text.
- Choose the flash filesystem from measurements and failure tests rather than
  assuming m5fs, littlefs, or another design in advance.

The language decision and its validation gates are recorded in
[`docs/adr/0001-zig-first.md`](docs/adr/0001-zig-first.md). The initial system
layers and hardware boundary are described in
[`docs/architecture.md`](docs/architecture.md).
The shared SMP service model for graphics, audio, storage, and a future SQLite
service is recorded in
[`docs/adr/0002-smp-services.md`](docs/adr/0002-smp-services.md).
Its first host-only transport result is recorded in
[`docs/measurements/2026-10-25-spsc-ring-host.md`](docs/measurements/2026-10-25-spsc-ring-host.md).
The first physical CPU0/CPU1 transport result, still using FreeRTOS only to
start and place the tasks, is recorded in
[`docs/measurements/2026-10-25-espidf-smp-mailbox.md`](docs/measurements/2026-10-25-espidf-smp-mailbox.md).
The static-analysis and emulator policy is recorded in
[`docs/adr/0003-quality-and-emulation.md`](docs/adr/0003-quality-and-emulation.md).
The timer-interrupt and scheduler boundary is recorded in
[`docs/adr/0004-timer-and-scheduler-boundary.md`](docs/adr/0004-timer-and-scheduler-boundary.md).
The native RV32 context and CLIC trap contract is recorded in
[`docs/adr/0005-riscv-context-and-trap-contract.md`](docs/adr/0005-riscv-context-and-trap-contract.md).
Its first separate-stack execution result is recorded in
[`docs/measurements/2026-10-25-esp-emu-context-switch.md`](docs/measurements/2026-10-25-esp-emu-context-switch.md),
and the physical ESP32-P4 result is in
[`docs/measurements/2026-10-25-tab5-context-switch.md`](docs/measurements/2026-10-25-tab5-context-switch.md).
The first Zig Timer Group driver and native asynchronous interrupt window
are described in
[`docs/adr/0006-bounded-native-timer.md`](docs/adr/0006-bounded-native-timer.md).
The repeated timer/interrupt-restoration result is recorded in
[`docs/measurements/2026-10-25-esp-emu-native-timer.md`](docs/measurements/2026-10-25-esp-emu-native-timer.md).
The free-running clock and timer-driven task-switching contract is in
[`docs/adr/0007-native-preemption-and-elapsed-time.md`](docs/adr/0007-native-preemption-and-elapsed-time.md).
The first two-worker preemption and delayed-tick result is recorded in
[`docs/measurements/2026-10-25-esp-emu-native-preemption.md`](docs/measurements/2026-10-25-esp-emu-native-preemption.md).
Opt-in RV32F context handling and the full-register preemption probe are
described in
[`docs/adr/0008-opt-in-eager-rv32f-context.md`](docs/adr/0008-opt-in-eager-rv32f-context.md).
Its integer/FP separation and host-bank restoration result is recorded in
[`docs/measurements/2026-10-25-esp-emu-rv32f-preemption.md`](docs/measurements/2026-10-25-esp-emu-rv32f-preemption.md).
Native task calls, sleep/block/wake, and completion/reaping are defined in
[`docs/adr/0009-native-task-lifecycle.md`](docs/adr/0009-native-task-lifecycle.md).
The first live sleep/block/wake/exit result is recorded in
[`docs/measurements/2026-10-25-esp-emu-task-lifecycle.md`](docs/measurements/2026-10-25-esp-emu-task-lifecycle.md).
Latched event notifications, masked waits, and deferred task replies are
defined in
[`docs/adr/0010-latched-task-events.md`](docs/adr/0010-latched-task-events.md).
Their first native ECALL and timer execution result is recorded in
[`docs/measurements/2026-10-25-esp-emu-task-events.md`](docs/measurements/2026-10-25-esp-emu-task-events.md).
Bounded request/completion channels and notification commit semantics are
defined in
[`docs/adr/0011-event-driven-spsc-channels.md`](docs/adr/0011-event-driven-spsc-channels.md).
The first bounded native request/completion result, including the ring's
non-power-of-two counter-wrap correction, is recorded in
[`docs/measurements/2026-10-25-esp-emu-spsc-channels.md`](docs/measurements/2026-10-25-esp-emu-spsc-channels.md).
CPU1-to-CPU0 owner notifications and bounded borrowing of IDF's IPI line are
defined in
[`docs/adr/0012-owner-inbox-and-borrowed-ipi.md`](docs/adr/0012-owner-inbox-and-borrowed-ipi.md).
The first remote-wait and IDF-restoration result is recorded in
[`docs/measurements/2026-10-25-esp-emu-owner-ipi.md`](docs/measurements/2026-10-25-esp-emu-owner-ipi.md).
Reverse wakeup, CPU1's WFI service, and restoration of both hosts are defined
in
[`docs/adr/0013-duplex-ipi-and-wfi-service.md`](docs/adr/0013-duplex-ipi-and-wfi-service.md).
The first duplex request/completion, WFI, stop-IPI, and host-restoration result
is recorded in
[`docs/measurements/2026-10-25-esp-emu-duplex-wfi.md`](docs/measurements/2026-10-25-esp-emu-duplex-wfi.md).
Independent CPU1 task execution, owner-local handles, and task-context service
work are defined in
[`docs/adr/0014-owner-local-cpu1-tasks.md`](docs/adr/0014-owner-local-cpu1-tasks.md).
Their first two-task execution, native stack checks, and dual-owner result is
recorded in
[`docs/measurements/2026-10-25-esp-emu-cpu1-tasks.md`](docs/measurements/2026-10-25-esp-emu-cpu1-tasks.md).
CPU1 timer ownership, deadline wakeup, and non-yielding-task preemption are
defined in
[`docs/adr/0015-cpu1-timer-and-preemption.md`](docs/adr/0015-cpu1-timer-and-preemption.md).
Their first delayed-tick, deadline-wakeup, and dual-timer result is recorded
in
[`docs/measurements/2026-10-25-esp-emu-cpu1-preemption.md`](docs/measurements/2026-10-25-esp-emu-cpu1-preemption.md).
Three physical Tab5 boots, including the CLIC return and IPC endpoint-lifetime
corrections found on silicon, are recorded in
[`docs/measurements/2026-10-25-tab5-native-smp-preemption.md`](docs/measurements/2026-10-25-tab5-native-smp-preemption.md).
Opt-in CPU1 floating contexts and preservation of IDF's raw FP bank are
defined in
[`docs/adr/0016-cpu1-floating-contexts.md`](docs/adr/0016-cpu1-floating-contexts.md).
The emulator and three physical CPU1 FP runs are recorded in
[`docs/measurements/2026-10-25-tab5-cpu1-floating.md`](docs/measurements/2026-10-25-tab5-cpu1-floating.md).
An explicit overlap handshake for simultaneous FP owners on both cores is
defined in
[`docs/adr/0017-simultaneous-floating-owners.md`](docs/adr/0017-simultaneous-floating-owners.md).
Its emulator and three physical overlap results are recorded in
[`docs/measurements/2026-10-25-tab5-simultaneous-floating.md`](docs/measurements/2026-10-25-tab5-simultaneous-floating.md).

## Bootstrap checks

Install the pinned Zig toolchain into the ignored `.tools/` directory:

```sh
sh tools/bootstrap-zig.sh
```

Run the host-side Zig tests and the same ABI probe implemented in C, Zig, and
Rust:

```sh
sh tools/run-static-analysis.sh
.tools/zig-0.17.0/zig build test
sh tools/run-language-probe.sh
```

Static analysis also compile-checks the architecture contract for the pinned
RV32IMAF target, so a host ABI success cannot hide a target layout/type error.

The probe is not a Tab5 performance result. It verifies the language boundary
and establishes a repeatable comparison harness before target-specific code is
introduced. The first host baseline is recorded in
[`docs/measurements/2026-10-25-language-probe-host.md`](docs/measurements/2026-10-25-language-probe-host.md).

The fast hosted CI gate runs formatting, ZLint, ShellCheck, Debug and
ReleaseSafe Zig tests, and the three-language ABI probe. ZLint is pinned and
checksum-verified by `tools/bootstrap-zlint.sh`; its selected semantic rules
are warnings-as-errors. This gate requires no target hardware.

Run the ESP32-P4 core smoke under the pinned official Espressif emulator with:

```sh
sh tools/run-esp-emu-smoke.sh
```

This builds a separate revision-3 ESP32-P4 image, boots both emulated cores,
and checks the 100,000-message SMP mailbox. The corresponding hosted workflow
is manual while the native timer and scheduler are still being built. An
emulator pass is target-execution evidence, but it is not evidence for Tab5
power, DMA, display, touch, audio, SD, timing, or physical-device reliability.
The initial result is recorded in
[`docs/measurements/2026-10-25-esp-emu-core-smoke.md`](docs/measurements/2026-10-25-esp-emu-core-smoke.md).
The first scheduler-policy and periodic-interrupt results are recorded in
[`docs/measurements/2026-10-25-scheduler-policy-host.md`](docs/measurements/2026-10-25-scheduler-policy-host.md)
and
[`docs/measurements/2026-10-25-esp-emu-periodic-timer.md`](docs/measurements/2026-10-25-esp-emu-periodic-timer.md).
The corresponding ESP-IDF-hosted physical timer result is recorded in
[`docs/measurements/2026-10-25-tab5-periodic-timer.md`](docs/measurements/2026-10-25-tab5-periodic-timer.md).

Build the first ESP32-P4 firmware using the pinned ESP-IDF v5.4.4 setup:

```sh
sh tools/build-espidf.sh
```

This firmware currently lets ESP-IDF perform boot and FreeRTOS SMP startup,
then crosses the handwritten C ABI into Zig and prints the detected chip,
heap, PSRAM, and Flash information. Zig then owns bounded internal-RAM and
PSRAM arenas, exercises the platform cache-sync contract, and verifies
memory-to-memory AXI-GDMA across internal RAM and PSRAM. It then paints a
bounded RGB565 test pattern from Zig into the display driver's scanout buffer
without an intermediate full-frame copy and measures physical refresh events.
It is a bring-up backend, not yet the native nihOS scheduler. The
physical-device results are recorded in
[`docs/measurements/2026-10-25-espidf-zig-bootstrap.md`](docs/measurements/2026-10-25-espidf-zig-bootstrap.md)
and
[`docs/measurements/2026-10-25-tab5-display-scanout.md`](docs/measurements/2026-10-25-tab5-display-scanout.md).
The first idle touch-poll result is in
[`docs/measurements/2026-10-25-tab5-touch-bootstrap.md`](docs/measurements/2026-10-25-tab5-touch-bootstrap.md).

## Project boundary

nihos is a new, independent project. It is not MeOS and is not presented as a
work by MeOS author shi3z.

No MeOS source code is included in this initial repository. Any future reuse
of a HAL, driver, or other implementation must first have a verified license
or explicit permission, preserve attribution, and document the imported
boundary and modifications.

Sources used as specifications, references, or dependencies are recorded in
[`provenance.toml`](provenance.toml). A source marked `reference-only` must not
be copied into the repository.

## Repository policy

- The repository is public from its first commit.
- The fast host CI gate runs on every pull request and push to `main`.
- The ESP32-P4 emulator smoke is manually dispatched until it becomes a
  stable, useful gate for the native kernel rather than ESP-IDF bring-up.
- Hardware claims require measurements on a physical Tab5; host builds and
  simulators will be reported separately.

## License

Original nihos code and documentation are available under the
[MIT License](LICENSE) unless otherwise noted. Third-party components, if
introduced, will retain their own licenses and notices.
