# C6 Hosted 2.13.1 time-candidate OTA — 2026-11-01

The user authorized the upgrade of the attached Tab5 C6 to the experimental
Hosted 2.13.1 image containing the C6 SNTP snapshot service and Network Split.
This is an experimental firmware change; it is not proof of C6 flash readback,
independent recovery, NTP synchronization, production reliability or iroh.

The reviewed C6 app was 1,278,048 bytes with SHA-256
`7f036e616df4d4782015caf30f185f7859af115438f394463600d0f8d69995be`.
The P4 OTA fixture was SHA-256
`a722899c7eff0554a2b1af68b159f6cec9e4a7f471c4b22459a20beee75d8265`.
The same C6 candidate had previously been transferred through a write-blocked
P4 simulation; see [simulation record](2026-11-01-c6-time-ota-simulation.md).

The first physical attempt stopped at `PowerEnable`, before the start token or
any OTA request. The P4 was restored and its full 16 MiB verified. A single
retry separately captured and verified the P4 backup, identified the P4,
verified its 4 MiB app layout and the exact fixture, and observed the mapped
candidate hash and C6 1.4.1 origin before sending the one-shot token. The P4
reported all 1,278,048 bytes acknowledged and a post-reboot Hosted 2.13.1
version response. Its capture SHA-256 is
`9e8c336f6201a5a2f0b539f753d1de8373e3f32383cf9e75f758ec0ec1dcf8dd`.
The P4 flash was then restored and all 16 MiB verified against backup SHA-256
`80fef2c6803dde580d6cb6dbb64d2e8ff8666a4b0ba53f8d8e0c10e7b40b30d5`.
The P4 was reset, but the restored application's boot log was not captured.
The C6 was intentionally left on the 2.13.1 firmware.

The first subsequent time-service probe observed Hosted 2.13.1 but failed before
a time result (`status=0`, `error_code=0x0c`, `got_result=0`). It did not
prove a complete DHCP/DNS configuration, CustomRpc or SNTP success. The P4
was again fully restored and verified against the same full-flash SHA-256. A
second diagnostic probe reported `Malformed` when consuming RPC 609, the
GetDhcpDnsStatus response, after the station had reported connected. Its P4
flash was also restored and verified. Upstream source can emit `0.0.0.0` while
the address is not ready; P4 handling was updated to treat an incomplete
snapshot as unavailable, never as an assigned address. The earlier response was
not captured byte-for-byte, so its exact content and root cause remain unknown.

A third P4 time fixture, SHA-256
`4ad0a85ef82c1c32aff5eb0381ab21a915403661c1e51955efc927d02c0489f2`,
ran with the revised handling. It reported C6 2.13.1, station connected, a
complete C6 address snapshot, a correlated CustomRpc acknowledgement and
result, and `synced=1`. The returned Unix time was `1793533453`
(2026-11-01 11:44:13 UTC / 20:44:13 JST), with sync age zero at the C6
snapshot. The P4 reported 25 completed snapshot attempts, including the
successful one. At the subsequent host observation, the host clock read
2026-11-01 11:44:21 UTC, eight seconds after the sample. This is an approximate
comparison including observation/transport delay, not a measurement of clock
error or an independent authentication of NTP. Capture SHA-256:
`abfaea2bcce8cf669a49dd8ca0946ee5c6c5e3830d59ebee587007ed4a1680f1`.

The exact P4 fixture and its partition were verified immediately before the
capture. Afterward the affected P4 spans were restored and the full 16 MiB
matched backup SHA-256
`80fef2c6803dde580d6cb6dbb64d2e8ff8666a4b0ba53f8d8e0c10e7b40b30d5`.
The P4 was reset; the restored application's boot log was not captured. This
is a single successful C6 SNTP/CustomRpc device run; it does not establish the
running image's hash, trusted time, behavior after AP loss or power cycle, or
CPU and memory savings. An offline checker recorded the bounded result and host
clock comparison, and its negative tests reject incomplete/error captures.

Private captures, candidate bytes, command logs, backups and restoration checks
are under `/private/tmp/nihos-c6-time-ota-upgrade-physical-20261101/`,
`/private/tmp/nihos-c6-time-ota-upgrade-physical-20261101-retry1/`, and
`/private/tmp/nihos-c6-time-after-upgrade-20261101/`,
`/private/tmp/nihos-c6-time-after-upgrade-diagnostic-20261101/`, and
`/private/tmp/nihos-c6-time-after-upgrade-pending-20261101/`. The 2.13.1 -> 1.4.1
rollback and independent recovery for a C6 that no longer boots remain
unverified. The time service uses unauthenticated SNTP and has no established
trust or rollback policy.
