# ESP-AT client controller

`esp_at.zig` decodes the bounded passive-socket/BLE receive profile.
`at_commands.zig` encodes a closed set of typed commands, escaping quoted
strings and rejecting control-character injection. `at_controller.zig`
owns one command slot, copied TX buffers, a staged socket read and profile
negotiation. It is single-owner code without allocation, OS calls or a device
driver. It is not yet a native `netd` service or a socket-handle table.

`c6_sdio.zig` now supplies the C6 FIFO/counter/credit layer. A native slot-1
driver and a separate [boot fixture](../../probes/c6-sdio/README.md) connect it
to the controller. That path is host-tested and image-built; it has no physical
SDIO qualification or permanent IRQ/service integration yet.

## Adapter contract

1. Reset/recover the physical link, flush all old RX bytes and wait for the
   C6 to finish booting. Call `recover(now, per_command_timeout)` once.
2. Repeatedly obtain `tx(now)` and write what the transport can accept. Call
   `consumeTx(actual_count, now)` before feeding responses to those bytes.
   Zero progress does not extend the deadline. Header/payload slices are
   borrowed until the next mutating controller call.
3. Drain RX even while TX is empty or an application request is pending.
   Feed each byte through `push(byte, now)`. Copy/publish notices before the
   next push: line/BLE data slices are borrowed from the decoder.
4. Only the `profile_ready` notice permits normal submission. Version lines
   from AT+GMR arrive as line notices; record them without logging credentials.
5. `submit(command, now, absolute_deadline)` copies the command's input bytes.
   Keep polling TX/RX and schedule `expire(now)` even when the link is silent.
   All times use one monotonic unit chosen by the adapter.
6. Drain `takeCompletion()` before submitting again. Successful socket read
   bytes are staged independently of BLE notices and committed only after OK.
   They remain borrowed until the next submit/recover, so copy them first.
7. On loss/overflow/ambiguous TX, call `transportFailed()`. Cancellation also
   invalidates the session. An observed `ready` banner does so automatically.
   Fail all application resource handles, drain the failure completion, then
   perform physical recovery and the full profile again. Do not simply call
   recover on the old byte stream. Never replay an ambiguous application send.

The adapter must not re-enter the controller from a callback/interrupt or call
it concurrently. IRQs should wake the owner and publish DMA completion records;
the owner performs the parsing. Queue capacity/backpressure and deadline wakeups
are adapter responsibilities. If it cannot preserve a notification or byte,
it must surface the loss rather than silently continue the session.

## Completion semantics

CIPSEND's initial OK and prompt are intermediate. Only SEND OK after all
payload bytes have been acknowledged by the transport succeeds; SEND FAIL or
ERROR rejects the operation. SEND OK means accepted by the C6 protocol stack,
not acknowledged by the remote application. BLE writes use a prompt and final
OK without a preliminary OK. GATT service/characteristic indices must come
from discovery; a CCCD subscription is a descriptor write, e.g. `{1, 0}` for
notifications. Negotiated MTU limits still apply below the protocol's cap.

The fixed profile sets normal mode, echo off, transient settings, multiplexed
passive sockets, CIPDINFO=0 and BLE client role. The resource table must still
interpret connect/disconnect URCs, socket EOF and resource generations; raw
AT link IDs are internal prototype arguments, not public nihos handles.
No connection success, peer acknowledgement or real-device behavior is
inferred from a host transcript or target compilation.
