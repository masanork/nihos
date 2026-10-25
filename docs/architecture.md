# Architecture bootstrap

nihos is built as a vertical Tab5 port first. It does not begin with a generic
HAL designed in isolation.

```text
applications and optional WASM
              |
       kernel services
     VFS / IPC / handles
              |
        nihOS kernel
 scheduler / memory / SMP
              |
       stable platform ABI
       /                 \
ESP-IDF bring-up       native ESP32-P4
backend                backend
       \                 /
             Tab5 board
```

## Layers

- `kernel/`: scheduling policy, capabilities, IPC, VFS, and resource tables.
- `arch/riscv32/`: traps, atomics, context frames, privilege, and PMP.
- `soc/esp32p4/`: CPU startup, interrupts, cache, DMA, PSRAM, and Flash rules.
- `board/tab5/`: pins, power sequencing, display, touch, audio, SD, and C6
  connections.
- `compat/espidf/`: the only place that may include ESP-IDF headers.
- `fs/`: a small VFS, a direct littlefs adapter for internal NOR, and a
  removable-media backend for SD.

Directories are introduced only when their first tested implementation is
added. The current `src/platform` module establishes the ABI layout first. A
bounded SPSC transport in `src/kernel` is the first common primitive for
cross-core system services; wakeup, cancellation, and scheduler policy remain
separate from the ring.

## Two backends

The ESP-IDF backend is a bring-up oracle. It proves hardware sequences and
provides a known implementation against which the native backend can be
measured. It may use FreeRTOS SMP temporarily.

The native backend uses the Espressif boot path and licensed low-level support
but owns scheduling, interrupts, resources, and services. Kernel code must not
know which backend provided the platform ABI.

ESP-EMU is a test environment for target binaries, not a third backend. The
same ESP-IDF-hosted Zig code can run there with a revision-3 target profile,
but emulator-only device models must not leak into the platform ABI or native
drivers.

## Hardware contracts

The platform boundary models resources, not generic convenience calls.

- Display scanout owns framebuffer format, stride, rotation, and vsync.
- DMA buffers carry direction, alignment, lifetime, and cache state.
- Block devices report erase and transfer geometry and removable-media state.
- CPU startup defines the shared-memory and interrupt protocol before CPU1 is
  allowed to call any service.
- Flash writes require an explicit guard that prevents unsafe execution or
  PSRAM access on the other core.

## Storage direction

- Internal NOR configuration and small writable state: littlefs core with a
  nihOS block adapter.
- Large Quake PAK files and media: SD FAT/exFAT with large batched reads.
- Immutable boot assets: a simple read-only packed partition if measurements
  justify it.
- M5FS implementation: not imported. Its atomic-replace and fault-test
  requirements are retained as specifications.
- SQLite: a future single-owner `sqld` system service over the nihOS storage
  service, not a library entered concurrently by arbitrary applications. SMP
  placement is a scheduler decision rather than a permanent CPU1 assignment.

## Bring-up order

1. Host ABI and data-structure tests.
2. ESP-IDF boot and serial output through the C ABI.
3. Internal allocator, PSRAM discovery, and cache/DMA tests.
4. Display scanout and vsync, then touch input.
5. Timer interrupts and a single-core scheduler.
6. CPU1 startup, IPI, atomics, and bounded cross-core rings.
7. Block I/O, littlefs, and fault injection.
8. Audio, SD assets, C6 networking, and performance applications.

Every stage records whether evidence is host-only, ESP-IDF-hosted, native
firmware, emulator-executed, or physical Tab5 behavior. Emulator execution can
gate boot, traps, SMP ordering, and later scheduler/system-call scenarios. It
cannot qualify board power sequencing, peripheral compatibility, display or
audio quality, storage durability, or real-time performance.

The first four stages are complete as of 2026-10-25. Stage 2 is physical
Tab5 evidence, but remains ESP-IDF-hosted: ESP-IDF and FreeRTOS still own boot,
interrupt setup, and scheduling before control crosses the platform ABI into
Zig. Stage 3 is complete at bring-up depth: bounded Zig arenas work in both
internal RAM and PSRAM, aligned cache ownership transitions work, and real
AXI-GDMA copies have been verified across all four internal/PSRAM paths.

Stage 4 is complete at initial display depth. The pinned official NoGLIB BSP
detects and initializes the panel, but the platform ABI exposes only fixed
display facts, one writable RGB565 scanout lease, present, and vsync. Zig
paints the scanout buffer directly, so there is no second full-screen buffer
or copy. A physical Tab5 delivered repeatable refresh callbacks at about
65.47 Hz. The same ABI now initializes the panel-matched touch controller and
returns bounded five-point snapshots; repeated idle reads succeed on the
physical device. Double buffering, tear-free swaps, visible-pattern
confirmation, and an actual pressed-coordinate trace remain open. Timer and
single-core scheduler work is the current architecture checkpoint.

Stage 5 is now complete only at policy-and-oracle depth. An allocation-free
Zig scheduler implements fixed-priority selection, round-robin fairness within
a priority, sleep/wake, blocking, bounded capacity, and generation-checked
task handles. A saturating atomic counter hands periodic interrupt ticks to
safe scheduler context, and the ESP-IDF oracle has delivered those interrupts
through the stable ABI in ESP-EMU and on a physical Tab5. A Zig Timer Group
driver now delivers asynchronous interrupts through nihOS's own trap entry in
ESP-EMU, using the bounded resource lease in ADR 0006. ADR 0007 extends this
with free-running elapsed-time accounting and timer-driven selection of two
integer-only tasks on separate stacks. Native physical timer qualification
and physical preemption remain open. FreeRTOS hosts the
bootstrap outside these bounded native execution windows.

The first native-port contract is now fixed and host-tested: a 128-byte RV32
integer switch frame, a 160-byte aligned exception-frame reservation, separate
optional RV32F state, and lossless ESP32-P4 CLIC cause decoding. This is a data
layout milestone. A matching save/dispatch/restore path now uses private
per-core interrupt stacks and a Zig dispatcher. ESP-EMU and a physical
revision-1.3 Tab5 have completed a controlled switch from the ESP-IDF
bootstrap stack to a separate Zig task stack and back. The nihOS vector is
installed for bounded synchronous `ecall` and asynchronous timer windows;
normal CLIC and timer ownership outside those windows remain with ESP-IDF.
Physical evidence currently covers the synchronous round trip. The physical
test also established that native switching must coordinate the P4 hardware
stack bounds. The trap path now stops monitoring only across the actual stack
change, installs the interrupt-stack or selected-task bounds, and resumes
monitoring before running code on that stack. It verifies the original
FreeRTOS bounds after the controlled round trip.

ADR 0008 adds explicit RV32F contexts on CPU0. Integer workers perform no FP
context transfers; opted-in workers preserve all 32 registers and `fcsr`
across native timer preemption in ESP-EMU. The physical IDF FP bank is also
restored before the bounded window ends. Lazy ownership, native CPU1 FP
switching, and physical qualification remain separate gates.

ADR 0009 connects live ECALLs to scheduler policy through a reusable RV32
runtime. Sleep and block preserve a resumable reply, returning from a task
creates an explicit terminal completion, and only reaping permits slot reuse.
Generation exhaustion retires slots instead of reviving stale references.
The emulator scenario includes an idle bootstrap interval while both workers
sleep. Cross-core lifecycle ownership and application isolation remain open.

ADR 0010 adds masked event waits and latched notifications. Pending-bit
consumption and wait registration share one serialized kernel operation;
matching notification makes the task ready and delivers its saved reply
before resuming. The emulator exercises preposted/coalesced events,
nonmatching notifications, blocked delivery, bit 31, and terminal/stale
handle rejection. This CPU-local primitive does not yet accept CPU1/IPI or
native device-IRQ completions. Events provide wakeups; message data stays in
separate queues.

The cross-core ring portion of stage 6 has also been exercised early through
the ESP-IDF oracle. A CPU0 Zig producer and CPU1 Zig service task exchanged
100,000 ordered request/completion pairs through the bounded SPSC rings on a
physical Tab5. This validates the current RISC-V atomic and coherent-memory
assumptions under FreeRTOS task placement. It does not complete stage 6:
native CPU1 startup, IPI wakeup, scheduler integration, cancellation, and
frame-load interference remain open.
