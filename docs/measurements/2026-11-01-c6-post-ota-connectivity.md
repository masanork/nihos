# C6 connectivity after SDIO OTA

One Tab5 warm-boot qualification of the C6 diagnostic firmware installed by
[the SDIO OTA run](2026-11-01-c6-sdio-ota.md). It checks the diagnostic RPC,
Wi-Fi station address acquisition and BLE advertising observation; it does not
measure long-term reliability, external application traffic, BLE connections,
C6 TCP/IP offload, or cold power cycling.

Under the shared board writer lock and exclusive serial lease, P4 rev 1.3 was
identified and its full 16 MiB flash was saved and verified. Two P4 fixture
images were installed, verified immediately before their respective captures,
and then the original P4 loader and affected application span were restored.
A complete verify against the immediately preceding backup succeeded; backup
SHA-256 `0a21266492da4c6f3e643ce481de3b723948a3871d59216b5d3c53c4e3c80ee0`.
The restored P4 was warm-reset; its post-restoration boot was not captured.
No OTA request or C6 firmware write was issued in this test.

## Diagnostic version response

P4 preflight image SHA-256
`affdd57d91e948085bfef59d1b35f66e12b28ed6133fd632a7b71faa723d0643`.
Its mapped candidate SHA-256 matched the installed C6 OTA candidate. The C6
responded chip ID 13, Hosted 1.4.1, `diag_known=1`, uptime 1 second and free
heap 252,784 bytes. This proves the new diagnostic extension remained available
at this warm boot after the previous P4 restoration. Heap is an instantaneous
C6 value before this test's Wi-Fi/BLE workload, not a free-heap minimum or a
measurement of contiguous RAM. Capture SHA-256
`7e1f7b9104898a62dd79a6398b31d384f004ccf59aca72d0746d9d8326aeea98`.

## Native network profile

Previously qualified P4 normal-network fixture SHA-256
`244e4ef168de15d3132393bac8d98c89aefa954d8153fe845f930799936d805d`, with
normal storage/device suite disabled. One warm boot, with a 30-second capture
window after network-ready, reported:

- P4 Hosted station acquired an IPv4 DHCP lease once (`station=12`, nonzero
  IP, `acquisitions=1`, `error_code=0`, `failures=0`). DHCP was handled by P4;
  this is not C6 IP-stack offload.
- BLE discovery reached phase 4, completed 7 controller commands, observed 16
  advertisements, and reported zero malformed events, status errors and timeouts.
- UI frame and both CPU tick counters advanced in the sampled window.
- No native trap appeared. This does not prove BLE pairing/HID or sustained
  network application traffic.

Capture SHA-256
`6ae56c912a6bf2175a65770aaef1eb5a640203fabb7da6ef395c571e8c247f6a`.
Private logs, exact P4 binaries, backup and restoration receipt are in
`/private/tmp/nihos-c6-postota-validation-20261101/`; logs and backup are not
committed because they can include private network/device information.

The C6 application hash is the source artifact sent by the earlier OTA and
associated with the diagnostic extension; this test did not read C6 flash.
Recovery, interruption, cold power, repeated OTA, TLS and Network Split are
still separate gates.
