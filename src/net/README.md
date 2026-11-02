# ESP-AT client controller

`tcp_wire.zig` provides a bounded IPv4/TCP packet codec for future use by the
ESP-Hosted P4 network path. It validates IPv4 and TCP checksums and rejects IP
fragments; it does not provide a TCP connection, retransmission, socket API,
native service integration, or a working SSH transport. The normal hosted
network service does not yet call it.

`arp_resolver.zig` resolves one IPv4 next hop from a caller-supplied lease,
validates replies, retries under a deadline and invalidates on an epoch change.
It is exercised through libslirp in the host SSH probe but is not yet owned by
the normal network service or connected to its DHCP lease lifecycle.

`tcp_link.zig` combines this resolver and the experimental TCP client for one
connection, with one full Ethernet frame owned until its send is confirmed.
The owner must queue incoming frames during a send, invalidate on an ambiguous
handoff or epoch change, and retain the tuple during TIME_WAIT. This has only
host fixture coverage and is not yet integrated with the native network owner.

`hosted_tcp_service.zig` wraps that connection in Hosted station frames and
binds handles and pending TX to the network owner's lease/reset epoch. It
rejects ambiguous partial sends and requires the caller to queue RX while a
frame is staged. Writes accept at most 446 bytes, leaving room for the
current headers in the normal short SDIO path's 512-byte Hosted frame limit;
callers must retry any remaining bytes. The OpenSSH/libslirp host fixture exercises this boundary;
normal `network_service.zig` does not yet call it. It is not a socket table or
a qualified DMA, Wi-Fi, reconnect, or device implementation.

`hosted_tcp_station.zig` maps the Hosted station's live DHCP lease and an
owner-supplied reset epoch into that service. Its experimental scheduling
helper runs station maintenance first, gives station/other priority traffic
precedence, and retains already-staged TCP frames. `hosted_tcp_rx.zig` adds a
four-frame bounded RX queue, preserving station processing and retiring only
the TCP handle on overflow. The owner must serialize completions and surface
queue failure; normal boot does not call either module yet.

`hosted_tcp_owner.zig` combines these prototypes behind one serialized owner,
tracks whole-frame completion, and requires a transport reset after an
ambiguous partial send. On TCP/RX failure it retires the TCP handle and
reports the error; callers can continue station maintenance on the next poll.
The OpenSSH host fixture uses this owner. An opt-in native build includes
experimental RX, TX and CPU0-only connection operations; native xy does not
call them. Its image has been linked and audited but not run on a device.

`ssh_hosted_tcp_io.zig` maps the owner's TCP stream to SSH pump partial I/O,
backpressure, EOF and failure. It requires the serialized caller to advance
the monotonic clock before each poll and revalidates the lease and handle for
each operation. The OpenSSH/libslirp host fixture uses this adapter. The
experimental native network owner can construct one for an established TCP
handle on CPU0; native xy does not yet use it.

`ssh_kex_driver.zig` advances the first key exchange after the caller has
exchanged SSH identification lines. It coordinates pending packet writes,
host-pin verification and NEWKEYS activation, and clears secrets on failure.
`ssh_identification.zig` provides the preceding bounded, nonblocking line
exchange without consuming the next packet. `ssh_connection.zig` coordinates
both stages on a single socket with a monotonic deadline, epoch checks and
fail-closed secret cleanup. The OpenSSH host fixture exercises the combined
path and a wrong-pin control. `ssh_client.zig` continues through public-key
authentication and an interactive PTY shell, with a bounded startup deadline.
`ssh_terminal.zig` adds bounded partial input and output, receive credit after
consumption, connection epoch checks and the remote close acknowledgement.
Production entropy, credential storage and the native application remain
outside these components.

`tcp_connect.zig` adds a host-tested bounded active-open state machine using
that codec. It handles SYN retransmission, tuple/ACK validation and a final
ACK; its result is only the handoff state for a future data-plane TCP client.
It has no ARP/routing adapter, socket service, data transfer, close handling,
or physical/real-network qualification and is not connected to SSH.

`tcp_stream.zig` is a separate host-tested experimental data plane with one
segment in flight, bounded receive buffering, retransmission, zero-window
probing and FIN handling.
`tcp_time_wait.zig` retains the tuple through a caller-supplied TIME_WAIT and
acknowledges duplicate FINs. These are not a complete TCP implementation:
among other gaps they lack congestion control, a socket table, routing and
integration with the normal network service. They must not yet be
exposed as an application socket.

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

`hosted.zig`, `hosted_station.zig` and `dhcp.zig` provide a separate, bounded
boot experiment for the **existing** C6 ESP-Hosted firmware: native P4 RPCs,
association, and P4-side DHCP. This is not the C6 TCP/IP-offload profile above.
See [Hosted fixture mode](../../probes/c6-sdio/README.md#existing-c6-firmware-hosted-station-mode).

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
