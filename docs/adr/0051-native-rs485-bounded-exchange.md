# ADR 0051: Bounded native UART1/RS485 exchange

- Date: 2026-10-28 JST
- Status: opt-in test transaction; external transceiver/peer qualification pending
- Based on main `2cb9143`, after PR #11 finite microphone input

`NIHOS_NATIVE_RS485=1 sh tools/build-native.sh device` selects one internal
UART1 loopback transaction ten seconds after normal boot. Normal builds leave
it disabled. The public fixture requires normal integer device display/console
boot and uses a separate `native-device-network-rs485` artifact directory.
Audio and microphone test profiles are separate; no simultaneous-fixture claim
is made. Display, IMU and network polling remain active.

CPU0 statically reserves UART1 for this fixture. Clock gates alone do not prove
a live owner: on the actual P4 their reset defaults leave UART1 APB/system
clocks enabled. Before adopting that state, the fixture rejects configured FIFO
memory, nonempty RX, non-idle TX, enabled interrupts or hardware RS485 mode.
This is an exclusive boot reservation, not a general runtime UART allocator.
The native shim checks its absolute UART1 alias against the pinned SDK and
rejects a UART0 alias as a compile-time negative control.

The initial format is nominal 115200 baud, eight data bits, no parity, one
stop bit, from XTAL40M with integer/fractional divider 347+3/16. There is no
DMA, UART interrupt, heap allocation or linked ESP-IDF UART driver. A maximum
64-byte request and expected reply are copied into CPU-owned static storage.
Each poll transfers at most eight FIFO bytes. Register-update and shutdown
handshakes are bounded; the vendor's unbounded update helper is not called.

On the board, GPIO20 is DI/TX, GPIO21 is RO/RX, and GPIO34 ties /RE and DE.
DIR low enables receive and disables transmit. Its low latch is installed
before output enable. A transmit request asserts DIR, waits at least 2 us after
the transfer, sends finite FIFO data, and keeps DIR asserted until **both**
TX FIFO empty and transmit FSM idle. Empty FIFO alone can truncate a final
stop bit. After that proof it drops DIR and receives a bounded exact reply.
Clock loss, UART framing/parity/overflow/break errors, excess reply, mismatched
reply or a one-second absolute timeout fail the transaction. Independent
cleanup drops DIR, resets only the reserved UART1, confirms empty/idle state,
disables its clocks/interrupts and disconnects peer pins. A failed direction
operation cannot skip the reset attempt. Failed cleanup never reports stopped.
There is no second request after done/failed; restart remains a separate gate.

`NIHOS_NATIVE_RS485_TEST` has three distinct modes:

- `loopback` (default): internal UART loopback; DIR stays low and UART TX is not
  mapped to GPIO20. This cannot qualify the SIT3088 or differential wiring.
- `no-loopback`: internal loopback off, RX routed to the SDK constant-high input
  and external TX unmapped. Full TX must finish, RX must stay empty, and the
  expected timeout must still cleanly return DIR low and close the UART.
- `peer`: internal loopback off, GPIO20/21 mapped to UART1, physical DIR control.
  An isolated bench peer must receive the exact request and send a **different**
  response. Local adapter echo cannot satisfy the expected reply.

The fixed test protocol is 64 bytes: `NIHOS485`, opcode (1 request / 2 response),
version 1, deterministic binary payload and big-endian CRC16/CCITT-FALSE.
The response payload differs by XOR 0xa5. This is a diagnostic protocol, not
Modbus, authentication or a production fieldbus service. `tools/rs485-peer.py`
provides a finite separate-adapter responder and retains exact request/reply
hashes. Device peer-pass alone still needs a matching independent peer receipt.
No peer transmission is performed by default.

Host fault models cover shift-register drain versus FIFO empty, bounded progress,
wrong/extra reply bytes, local-echo rejection, clock/timeout/UART faults,
independent shutdown, failed close and invalid admission. Evidence checks keep
internal, timeout-control and external-peer scopes distinct and bind candidate,
mode, capture and restoration identities. A generic native boot PASS cannot
substitute for UART or wire evidence.

Remaining gates include actual SIT3088 A/B and direction timing, a separate
RS485 peer, selectable termination/bias and cable conditions, repeated/reopen
operation, cold power-on, application IPC/streaming, Modbus or other framing,
DMA for larger transfers, and simultaneous active AP traffic.

Sources: [M5Stack Tab5 wiring](https://docs.m5stack.com/en/core/Tab5),
[Tab5 schematic](https://m5stack-doc.oss-cn-shenzhen.aliyuncs.com/1132/Tab5_Schematics_PDF.pdf)
page 4 (U18 SIT3088EEUA and J7), and pinned ESP-IDF v5.4.4 UART/GPIO LL and
register headers. No external RS485 driver source is imported.

Exact successful/control image identities, the initial gate-state failures and
restoration records are in the
[UART1 checkpoint](../measurements/2026-10-28-native-rs485.md).
