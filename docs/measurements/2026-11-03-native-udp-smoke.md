# Native short UDP smoke: first physical attempt

The opt-in smoke profile queues one 458-byte UDP payload for a configured
Ethernet peer and waits for a matching echo. This experiment does not establish
QUIC, iroh, routing, discovery, or an application socket API.

On 2026-11-03 candidate `bd3726539e16eb93484bfeca2a9294fb57c8f822` was
built with C6 time offload and the short UDP experiment enabled. Its native
application SHA-256 was
`f2c25530f47381c401aee5aca269ee0a34bc3d960e865804f4378deba5d48647`;
the native image audit passed with 49,600 bytes of SRAM heap. This candidate
uses the C6's saved Wi-Fi configuration. It does not flash C6 firmware.

The P4 obtained an IPv4 address and queued the datagram once. At the deadline,
the device reported `phase=4`, `queued=1`, `matched=0`, `rejected=0`,
`error_code=96` (deadline), and `close_error_code=0`. The Mac UDP listener
observed zero matching datagrams and sent zero echoes. These observations do
not establish whether the datagram was transmitted by the C6, filtered, or
routed to the intended peer. The P4 and Mac addresses were in different /24
and /16 networks; although the Mac's Wi-Fi identity matched the preflight,
the C6's saved AP identity was not independently established. A shared SSID
or BSSID observed on the Mac alone does not establish that both devices share
a reachable link. The experiment uses an explicit peer MAC and does not
implement gateway routing.

The test profile reported that writable SQLite service startup was disabled.
Before writing, the full 16 MiB P4 flash was backed up and verified against
the device. After the attempt, the original bootloader, partition table, and
overwritten application sectors were restored, and the entire 16 MiB flash
verified against the backup (SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`).
A subsequent passive serial capture observed the restored native firmware.
The backup and raw network captures remain private local artifacts.

Next, independently establish the C6 AP and both peers' addresses and masks,
then repeat only on a verified reachable link. Add send-stage diagnostics to
distinguish pending, accepted by Hosted, and independent peer receipt before
attributing a failure to the network or transport. Even a successful short
packet would not establish support for the 1200-byte QUIC Initial.
