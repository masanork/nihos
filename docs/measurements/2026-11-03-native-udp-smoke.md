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
and /16 networks. The Mac preflight's apparent Wi-Fi identity match was invalid:
macOS returned redacted SSID and BSSID values, so it compared placeholders.
Neither device's AP identity was independently established. Even a shared
SSID or BSSID would not alone establish peer reachability. The experiment uses an explicit peer MAC and does not
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

A subsequent diagnostic update accepts an optional expected BSSID in the
private peer configuration. When set, it compares that BSSID with the C6's
station-connected event and fails closed if the event is absent, malformed,
or different. Only a numeric match state is logged; no SSID, BSSID, or
password is logged by this comparison. Exact BSSID equality is an optional
experiment precondition, not a general test of reachability across a mesh or
multiple access points. The optional BSSID comparison has not yet been exercised on hardware.

## Subnet guard physical attempt

On 2026-11-03 candidate `201d00d2957f96d2062e596dfda9cdcb4313b1e2`
(native application SHA-256
`27f909112df154d3b3a6be930ba4f05e496861159f74374d3ff0fb0e44063b60`)
was run on the Tab5 with the C6's saved Wi-Fi configuration. The Mac's
configured peer IP and MAC matched its active interface immediately before
the write. No AP identity was inferred from macOS's redacted values, and the
optional BSSID comparison was not configured.

The C6 network became ready. The P4 reported `phase=4`, `queued=0`,
`sent=0`, `error_code=120`, `close_error_code=0`, and the Mac listener
received no matching datagrams. The candidate ELF's DWARF enumeration maps
error code 120 to `error.PeerNotDirect`: the configured Mac IPv4 address did
not belong to the subnet reported by the C6. The guard therefore stopped the
test before queueing. This result establishes a subnet mismatch at that
moment, not which access points the two devices used or where the earlier
packet was lost. The writable SQLite service disabled marker was observed.

Before installation, the entire 16 MiB P4 flash was backed up and verified.
After the attempt, the original overwritten ranges were restored and the
entire flash verified against that backup (SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`).
A subsequent passive serial capture observed the restored native firmware.
No C6 firmware was written. Raw network observations remain private.
