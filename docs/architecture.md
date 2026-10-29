# Architecture

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

The normal device image uses the permanent native backend in
`src/platform/native/main.zig` and `src/arch/riscv32/native_tasks.zig`
([ADR 0018](adr/0018-independent-native-boot.md),
[ADR 0019](adr/0019-permanent-native-task-owners.md)). The ROM and stock
second-stage loader start it; nihOS owns CPU1 release, scheduling, traps,
timers and IPI/WFI thereafter. Its task runtime never restores a hosted window.

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

## Connectivity direction

The public normal Tab5 build now enables the C6 driver by default and accepts
an unconfigured Wi-Fi state. The shared transport also supports physically
observed BLE HCI passive discovery. RTC and read-only power/IMU status share
the CPU0 board I2C owner. See [ADR 0047](adr/0047-default-connectivity-and-board-devices.md)
and the [device inventory](planning/tab5-native-device-support.md).

The intended service boundary puts Wi-Fi, TCP/IP and the BLE host on the C6,
exposed through ESP-AT over SDIO (ADR 0043). Its decoder/controller are
host-tested and its separate C6 firmware builds. The current physical path
instead preserves the factory ESP-Hosted 1.4.1 firmware: a native P4 slot-1
SDIO CPU0 boot fixture has associated with an AP, acquired IPv4 through P4
DHCP, and answered link-local IPv6 Echo. SLAAC is host-tested; the current AP
provided no router advertisements. The subsequent bounded, opt-in normal-boot
path integrates networking alongside the display; see
[ADR 0045](adr/0045-normal-boot-network-integration.md). Lease renewal, expiry
and reconnect now have a host-tested implementation under
[ADR 0046](adr/0046-native-network-lease-lifecycle.md). A real early-renewal ACK
and controlled C6-reset recovery are now [physically recorded](measurements/2026-10-27-network-lease-device.md).
Natural lease timing and long-duration recovery remain open. Application network services, C6 TCP/IP/BLE offload and IRQ-driven service
remain open. The normal storage profile now shares the SDMMC host with C6;
see the [device inventory](planning/tab5-native-device-support.md) for its gates. See [ADR 0044](adr/0044-c6-sdio-boot-transport.md) and the
[IPv6 evidence](measurements/2026-10-27-native-ipv6.md).

The normal image also includes finite speaker, microphone and UART/RS485
drivers ([ADR 0052](adr/0052-default-on-demand-device-drivers.md)). They remain
idle until requested; speaker and microphone serialize ownership of I2S0 and
their SRAM workspace. Inclusion does not qualify acoustic quality or external
RS485 wiring. With a valid IPv4 lease and DNS, the bounded SNTP client can set
and read back the RTC in UTC ([ADR 0053](adr/0053-network-time-to-rtc.md)).
Monotonic scheduler time stays separate from unauthenticated wall time.

## Storage direction

Read-only file access, filesystem services and writable log-store work have
separate profiles and qualification gates; the normal launcher is not a general
writable application environment. Internal NOR configuration uses the littlefs
adapter foundation. SD FAT/exFAT serves removable files and large assets. The
custom store explores integrating SQLite WAL with page/log/checkpoint/GC
ownership; persistent SQL durability remains a separate integration goal.
M5FS source is not imported.

SQLite already has a bounded, single-owner memory session, cancellation and
resource limits ([ADR 0040](adr/0040-bounded-single-owner-sqlite-session.md)).
The minimal C runtime and standalone RV32 link are defined in
[ADR 0041](adr/0041-minimal-c-runtime-and-standalone-sqlite-link.md).
The opt-in `sqlite` native profile executes that session on CPU0's retained
bootstrap after its qualification phases, with a no-I/O VFS
([ADR 0042](adr/0042-native-sqlite-flash-execution.md),
`src/platform/native/sqlite_probe.zig`). This is implemented bounded execution,
not a persistent `sqld` service. A production VFS, task/RPC, WAL persistence,
reboot readback and power-loss qualification remain separate work. SMP service
placement is a scheduler decision rather than a fixed CPU1 assignment.

## Bring-up and evidence

The original sequence was host ABI tests, ESP-IDF bring-up, allocator/PSRAM,
display/input, timer/scheduler, CPU1/IPI, storage and further peripherals.
The [ADRs](adr/) retain those dated checkpoints, including hosted windows that
restored FreeRTOS. They do not describe the current normal boot path.

- **Permanent native ownership:** ADR 0018 introduces the independent boot;
  ADR 0019 attaches the shared task runtime to permanent per-core trap owners.
  [ADR 0020](adr/0020-native-ipi-and-interrupt-wait.md) adds native inbox/IPI and
  interrupt-driven WFI; [ADR 0021](adr/0021-native-opt-in-floating-contexts.md)
  adds opt-in native floating contexts. The
  [task-owner measurement](measurements/2026-10-25-native-task-owners.md)
  records emulator preemption, sleep, exit, reap and slot reuse. Normal fast
  boot skips these qualification phases and runs the interactive session.
- **Physical normal-image evidence:** native display and the connected loop
  have [recorded Tab5 runs](measurements/2026-10-27-normal-boot-network.md).
  [Combined device operations](measurements/2026-10-28-default-devices.md) and
  [network-to-RTC synchronization](measurements/2026-10-28-network-rtc-sync.md)
  have their own candidate-bound physical results. These records do not
  qualify every new image, panel/input combination or long-duration workload.
- **Host and emulator evidence:** allocation, scheduler, networking, rendering
  and service fault tests run without hardware. ESP-EMU executes target boot,
  trap, SMP and scheduler scenarios; it cannot establish board power sequencing,
  peripheral compatibility, optical/acoustic quality, physical timing or storage
  durability. A device-profile link or image audit is build evidence only.

Current native entry points are `src/platform/native/main.zig`,
`src/arch/riscv32/native_tasks.zig` and the services under
`src/platform/native/`. Build flags and fixture boundaries are in the
[native boot guide](native-boot.md); the [device inventory](planning/tab5-native-device-support.md)
tracks implementation and remaining peripheral gates.
