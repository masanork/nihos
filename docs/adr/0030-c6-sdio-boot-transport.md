# ADR 0030: Qualify the C6 transport with an exclusive native boot fixture

- Status: accepted for initial qualification; host-tested and native image built; physical execution pending
- Date: 2026-10-27

## Decision

Add an ESP32-P4 slot-1 SDIO host and C6 byte stream to the ESP-AT direction
in ADR 0029. First qualify it in a separate CPU0-only native boot fixture.
Do not attach a controller-resetting polling driver to the permanent SMP
runtime or claim it arbitrates slot 0 microSD traffic.

The first combined link with the full scheduler bootstrap overflowed the
128 KiB native SRAM region by 12,160 bytes, before satisfying the minimum
heap requirement. Retain the established map and isolate this experiment.
The resulting fixture fits the same region with an unused heap reservation.
The exact code/data/stack and unused-tail sizes are recorded with its image
hash in the measurement record. It does not run an allocator or
qualify the memory budget of a combined OS/network/display workload.

## Layers

- `soc/esp32p4/sdio.zig`: exclusive slot-1 command/register/DMA engine,
  CMD0/5/3/7 enumeration, CMD52 function setup and bounded CMD53 transfers.
- `net/c6_sdio.zig`: cumulative counter arithmetic, credits, FIFO address and
  padding rules, at most one 512-byte peer receive buffer per send call.
- `platform/native/c6_probe.zig`: internal aligned DMA backing, ROM cache
  maintenance, fresh-peer drain and the existing AT controller.
- `probes/c6-sdio`: minimal native startup, timer/console and a vendor-LL-only
  pad/clock shim; CPU1 remains parked and interrupts remain disabled.

The raw host admits only the SDIO command family; memory-card read/write/erase
commands are not added to its allowlist. Register/DMA failures retire the
instance and stop/reset DMA; failed cleanup is reported. Backing is static
and cannot be reused by another caller after a failure.

## Peer synchronization

The peer must freshly boot the C6 firmware built in the previous milestone.
Resetting the P4 host or issuing CMD0 alone does not reset C6's cumulative
stream counters. Always reset C6 physically when recreating stream state.
Never rebase a new host onto live counters by silently skipping queued bytes.

Keep logical FIFO length separate from rounded DMA count. TX needs credits
before a transfer, and credit exhaustion yields back to the AT transaction's
deadline. Ambiguous transfer or interrupt-clear failure invalidates the stream
and AT session; do not replay. Interrupt-clearing races are not yet qualified
for an IRQ service. The polled counter path does not depend on IRQ edges.

The prototype assumes the pinned C6 config's 512-byte receive buffers and ten
buffer credits. RX backlog above 128 KiB is a discontinuity error. Modular
counters cannot reveal a complete unobserved wrap, so these checks do not
constitute end-to-end loss detection under unbounded owner suspension.

## Qualification

The host suite covers command/response flags, slot-1 clock selection, function
setup, padding, modular counter boundaries, credit starvation, R5/DMA errors,
cleanup failure and retired-object rejection. A synthetic C6 peer checks the
complete AT profile and binary TCP/BLE exchange with 1/3/17/512-byte chunks.
This peer is a protocol model, not a physical C6 or SDMMC hardware emulator.

The native image reuses the SRAM/ROM/image digest audit and additionally
requires actual C6 fixture function symbols. A baseline kernel ELF must be
rejected. The native SDIO/AT path also code-generates in the default RV32
compile gate without requiring the SDK; building the pad shim/full fixture
is a separate SDK-dependent command.

See the [fixture procedure](../../probes/c6-sdio/README.md) and
[measurement record](../measurements/2026-10-27-c6-sdio-native-build.md).
No device was flashed or reset in this work. C6 recovery/backup access and
real native SDIO execution remain pending. Later gates are IRQ integration,
shared-controller arbitration, permanent service lifetime, resource handles,
TCP/BLE peer traffic, heap/latency/loss and interference with graphics/storage.

## Primary references

- [Pinned P4 register definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/soc/esp32p4/register/hw_ver1/soc/sdmmc_struct.h)
- [Pinned P4 LL operations](https://github.com/espressif/esp-idf/blob/v5.4.4/components/hal/esp32p4/include/hal/sdmmc_ll.h)
- [C6 slave protocol](https://docs.espressif.com/projects/esp-idf/en/v5.4.2/esp32c6/api-reference/peripherals/sdio_slave.html)
- [Pinned ESP-AT reference host](https://github.com/espressif/esp-at/blob/7c092f9aee793d6dbfae31e7585637baa14fb4ce/examples/at_sdio_host/ESP32/components/sdio_host/sdio_host_transport.c)

The existing nihos slot-0 implementation in the graphics/card branch was
inspected for DMA/cleanup conventions; its dirty files were not imported or
modified. No MeOS source was copied and its SD memory-card permissions were
not expanded to implement C6 transport.
