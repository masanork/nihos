# ADR 0052: Default on-demand native device drivers

- Date: 2026-10-28
- Status: implemented and host/build checked; combined-image physical validation pending
- Extends: [ADR 0047](0047-default-connectivity-and-board-devices.md),
  [ADR 0049](0049-native-audio-output-probe.md),
  [ADR 0050](0050-native-finite-microphone-input.md),
  [ADR 0051](0051-native-rs485-bounded-exchange.md)

## Decision

The normal `sh tools/build-native.sh device` image includes the finite speaker,
microphone and UART1/RS485 drivers alongside existing display, C6 Wi-Fi/BLE,
RTC, power-monitor and IMU services. Inclusion makes the three drivers
requestable in one image. It does not start playback, capture, UART clocks,
external transmission or codec configuration during boot.

`NIHOS_NATIVE_DEVICES=0` retains the smaller connected image. The low-level
ELF builder remains opt-in. Explicit AUDIO/MICROPHONE/RS485 and boot-test
fixtures keep their existing separate profiles and automatic fixture requests;
they cannot be combined with DEVICES. Non-normal display, storage, qualification
and emulator profiles do not implicitly enable the new service.

This does not implement camera capture or turn USB/card/touch qualification
profiles into normal OS services. Those require their own resource integration.
The previously observed standalone probe results do not qualify the new combined
image; external RS485 communication remains deferred.

## Requests and ownership

CPU0's live serial input accepts complete colon-prefixed lines:

| Line | Operation |
| --- | --- |
| `:devices` | Acknowledge status; the periodic service report lists availability, requests and storage |
| `:audio` | One bounded speaker tone |
| `:mic` | One finite 1024-byte microphone capture; statistics only, then PCM erasure |
| `:rs485-loopback` | One internal UART transaction; external transmit stays inactive |
| `:rs485-peer` | One external request/reply fixture, requiring a separate peer |

Terminate with LF or CR. Unknown, incomplete or overlong lines never dispatch.
Escape cancels a partial command and retains the usual UI Escape action.
`NIHOS_DEVICE_REQUEST` records the command kind (1 through 5 in table order of
operations: audio, mic, loopback, peer, status), acceptance, I2S owner, pinned
state and reserved workspace. `NIHOS_NATIVE_DEVICE_SERVICE.available=7` means
all three software drivers are included, not that external devices or wires
have been qualified. Its `requested` bitmap uses audio=1, microphone=2, UART=4.
Unused drivers do not generate full per-probe status records.

The board service's request API and UART bounded exchange API are CPU0
foreground contracts, not cross-core IPC. Speaker and microphone share I2S0,
clock pins and one SRAM workspace. Overlapping requests are rejected before
buffers, codecs or pins are changed. Clean terminal transfers can be requested
again. Reuse requires verified codec/amp shutdown, stopped DMA, returned
ownership and, for microphone input, successful PCM erasure/writeback.
Failed cleanup pins the controller and storage until reboot. UART remains
independent, with its existing bounded FIFO work, deadline, receive-direction
and closed-controller checks.

## Memory and Flash

The primary SRAM span, separate stacks and minimum 49152-byte static heap are
unchanged. A plain sum of the three old SRAM-only fixtures does not fit that
budget. The combined profile therefore places only the three foreground poll
wrappers and the named peripheral C functions in `.flash.devices`, after the
boot code in the already mapped first 64 KiB Flash page. IRQ, scheduler,
cache-off startup and mutable state stay in SRAM. These peripheral paths do not
disable the Flash mapping/cache and are not interrupt entry points.

The image auditor checks the section's RX permissions, bounds, position,
linker marker, exact function allowlist, complete byte coverage and actual image
payload. Unknown functions, writable sections, missing functions and extent
changes are rejected. Standalone probes retain their prior SRAM code placement.

The final local combined build leaves **50688 bytes** of primary static heap,
versus **56128 bytes** with DEVICES=0: **5440 bytes** of additional SRAM. Its
foreground device code occupies **9414 Flash bytes**. These are link-layout
measurements, not free-heap measurements from a running device.

No DMA storage is allocated at idle. The first accepted audio or microphone
request reserves **1536 bytes plus up to 63 alignment bytes** from CPU0's
bounded internal arena. This boot arena cannot free individual allocations;
the reservation remains until reboot and is shared by subsequent clean
transfers. It contains a 1024-byte PCM block and a disjoint 512-byte descriptor
area. It is not PSRAM and does not consume the other core's arena.

## Validation and remaining gate

Host Debug/ReleaseSafe tests cover the finite transfer lifecycles, exclusive
lease failure behavior and command parsing. Python tests exercise the strict
Flash boundary and incompatible-profile rejection. Static analysis, RV32 links,
DMA/UART negative-control compilation and separate legacy fixture builds pass.
The default combined and drivers-disabled images are also built/audited in CI.

The physical Tab5 was being used by a concurrent card-scene session during this
change. No combined candidate was written or represented as device-qualified.
Before landing the new default, obtain exclusive write ownership, retain and
verify exact candidate bytes, confirm idle produces no requests, then exercise
microphone/audio alternation, rejected overlap, repeated internal UART requests,
cleanup, continuing display/ticks/sensors/C6, and restoration of the prior image.
Audible quality, external RS485 peer/wires, cold power-cycle, power consumption
and long-duration operation remain separate observations.
