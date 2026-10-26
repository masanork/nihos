# ADR 0029: Offload TCP/IP and the BLE host to the C6 over SDIO

- Status: accepted direction; controller host-tested and C6 firmware built; hardware qualification pending
- Date: 2026-10-27

## Decision

Treat Tab5's ESP32-C6 as a network service processor. Keep Wi-Fi, TCP/IP,
DNS, the BLE host, controller and bonding state on the C6. Keep the native
nihos scheduler, graphics, input, editor and language runtimes on the P4.
ESP-IDF/FreeRTOS may run on the C6 without entering the P4 native kernel.
TLS can run on the C6, but certificate/hostname verification and its memory
cost require a separate qualification before HTTPS is exposed to applications.

Start with ESP-AT over the existing SDIO wiring. Do not assume compatibility
with the factory ESP-Hosted firmware: ESP-AT is a different C6 image and a
different application protocol. The SDIO byte stream does not use Hosted's
Ethernet/HCI framing. A P4 SDIO host driver is still required.

The initial reference is ESP-AT v4.1.1.0, exact commit
`7c092f9aee793d6dbfae31e7585637baa14fb4ce`. Its C6 configuration requests
ESP-IDF `8ad0d3d8f2faab752635bee36070313c47c07a13`. This is a reproducible
experiment candidate, not a claim that this is the newest release or an
approved production firmware. v4.1.1.0 uses the release-v4.1.0.0 manual.
Record the actual built SDK, config, image hash and AT+GMR output together.
Do not substitute the P4's v5.4.4 SDK silently.

## Service and ownership boundary

One P4 owner serializes all AT commands. `netd` and `bled` are logical client
interfaces to that owner, not two independent command senders. Use bounded
request/completion mailboxes, deadlines and leased buffers following ADR 0002.
Do not assign a service permanently to CPU1. Keep SDMMC controller arbitration
below the network service so microSD traffic can share hardware safely.

The first application contract needs TCP connect/send/receive/close, receive
readiness and EOF, plus BLE scan/connect/discover/subscribe and notification
events. UDP and server sockets follow only when implemented. Socket byte
streams must preserve partial send/receive semantics; BLE notifications remain
separate records. Handle the server's CCCD as discovered metadata, not a fixed
service or characteristic index.

Session identity and per-resource generation belong in application handles;
ESP-AT's small numeric socket/connection IDs are never durable handles. Reset
must fail all outstanding work, invalidate sockets, BLE subscriptions and
cached service indices, and require profile negotiation before new requests.
Resource-handle tables and application API wiring are not implemented here.

AT has no transaction IDs. After a timeout, truncated payload, RX loss or
malformed frame, stop admitting commands, reset/recover the link, then
negotiate again. Waiting for one more OK is not resynchronization. A spontaneous
`ready` banner invalidates the old session; it does not establish a new one.
Command phases matter: CIPSEND's initial OK and prompt are intermediate;
the owner waits for SEND OK/SEND FAIL before releasing the slot. URCs do not
complete requests. After reset, discard old queued bytes and completions.

## First implemented receive profile

`src/net/esp_at.zig` contains an allocation-free byte decoder and a command
gate, independent of the SDIO driver, ESP-IDF and kernel scheduling.

- Normal command mode, echo disabled, multiplexed sockets, `CIPDINFO=0`.
- All sockets use passive receive: `+IPD,<id>,<count>` announces availability.
  Arm a bounded read before sending `CIPRECVDATA`; its response carries the
  actual byte count but no socket ID, so the owner supplies that association.
- BLE client `+NOTIFY` and `+INDICATE` carry an explicit length. Consume that
  many binary bytes even when they contain CR/LF, NUL, `OK`, `ERROR` or `>`.
- At most 512 control-line bytes including CR, 1024 socket bytes per read and
  512 BLE bytes per record. These are provisional P4 protocol limits, not C6
  memory measurements. Larger available TCP counts are read in chunks.
- Return borrowed slices only until the next decoder push. The owner must
  copy/publish them to bounded queues first. Never call the decoder from an
  IRQ or let application callbacks re-enter it.
- Payloads require a CRLF trailer. Wrong framing, overflow or unsupported
  binary forms poison the decoder until link recovery. Passive UDP, active
  socket receive, CIPDINFO=1, passthrough, BLE server READ/WRITE, GATT read
  response payloads and BluFi data are outside this first profile.

The command gate permits one pending request, checks absolute monotonic
deadlines at completion as well as polling, and rejects stale epoch/serial
tokens without wrapping. `at_controller.zig` now adds profile negotiation,
typed command encoding, partial TX, send-prompt/final-response phases,
terminal-error cleanup and failure/reset handling. It stages read bytes until
the terminal OK so interleaved BLE notices cannot overwrite a read completion.
Handle tables, native service/queue wiring, backpressure and the SDIO adapter
remain to be implemented. See the [adapter contract](../../src/net/README.md).

TCP passive receive limits P4 buffering but does not bound C6 allocations or
make UDP lossless. BLE notifications need queue budgets and explicit overflow
reporting; TCP traffic cannot indefinitely delay draining BLE events. Keep
control/notification capacity available while a data consumer is slow.

## Qualification sequence

The first [host and RV32 compile results](../measurements/2026-10-27-c6-at-host.md)
are recorded separately from the remaining firmware and physical gates.
The [controller and C6 build result](../measurements/2026-10-27-c6-at-controller-build.md)
records the next milestone without claiming device execution.

1. Host decoder/gate tests, then a compile-only RV32 probe. This qualifies
   neither SDIO transport nor the running network service.
2. Build a C6 SDIO image using the pinned upstream SDK and resolved config.
   Confirm Wi-Fi, TCP/IP and BLE are enabled together. Stock C6 defaults use
   NimBLE; dedicated BLE HID AT commands are unavailable on this target.
   This compile gate now passes using `ports/esp32c6-at`, with upstream SDK
   patches verified in the actual source and the binary hashes retained.
3. Establish C6 flashing/recovery access, identify the actual module/flash,
   preserve the existing C6 image and NVS, and separately record the P4 image
   and OTA slot. Flashing or restoring the P4 does not restore the C6.
4. P4 SDIO bring-up: reset, enumerate, flow control, byte-accurate AT/ATE0/GMR,
   IRQ-driven receive and bounded transfer/recovery tests. Compare low-speed
   and intended-speed runs on the actual board.
5. TCP echo and BLE GATT notifications separately, then concurrently with
   sequence-numbered binary payloads. Measure C6 free/minimum heap, transfer
   rate, notification latency/loss, P4 SRAM and CPU time.
6. Add microSD/display workload, AP loss, peer loss, C6 reset and queue
   exhaustion. Require bounded errors, no stale handle reuse and successful
   reconnect/resubscription. TLS/HTTPS and BLE HID follow as separate gates.

If AT's serialized operations, resource limits or profiles fail measured
requirements, retain the application contract and replace the C6 endpoint
with a versioned binary RPC over SDIO using C6-local lwIP/NimBLE. Do not
create that protocol before the ESP-AT experiment identifies a concrete need.

## Alternatives

P4-local lwIP/NimBLE with ESP-Hosted remains a fallback when raw Ethernet/HCI
access or many P4-local sockets justify its larger port. A raw-IP VPN/TUN path
like MeOS's requires additional design under full socket offload. No raw-IP
path, general BSD compatibility or Classic Bluetooth support is promised.
The C6 supports BLE, not Classic Bluetooth.

## References

- [Pinned ESP-AT source](https://github.com/espressif/esp-at/tree/7c092f9aee793d6dbfae31e7585637baa14fb4ce)
- [C6 SDK pin](https://github.com/espressif/esp-at/blob/7c092f9aee793d6dbfae31e7585637baa14fb4ce/module_config/module_esp32c6_default/IDF_VERSION)
- [C6 defaults](https://github.com/espressif/esp-at/blob/7c092f9aee793d6dbfae31e7585637baa14fb4ce/module_config/module_esp32c6_default/sdkconfig.defaults)
- [SDIO Kconfig](https://github.com/espressif/esp-at/blob/7c092f9aee793d6dbfae31e7585637baa14fb4ce/main/interface/sdio/Kconfig)
- [TCP/IP commands](https://docs.espressif.com/projects/esp-at/en/release-v4.1.0.0/esp32c6/AT_Command_Set/TCP-IP_AT_Commands.html)
- [BLE command examples and binary notification records](https://github.com/espressif/esp-at/blob/7c092f9aee793d6dbfae31e7585637baa14fb4ce/docs/en/AT_Command_Examples/bluetooth_le_at_examples.rst)
- [Board wiring](https://docs.m5stack.com/en/core/Tab5)
- [Japanese experiment runbook](../planning/c6-network-offload.md)
