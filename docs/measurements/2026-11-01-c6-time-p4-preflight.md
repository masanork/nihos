# C6 time P4 integration and negative device preflight — 2026-11-01

The P4 experimental owner combines Hosted station setup, C6-owned Network Split
address status, and the time CustomRpc. It accepts only C6 2.13.1; it does not
start P4 DHCP when C6 networking is selected. It waits for a matching CustomRpc
acknowledgement and result in either order. It revokes the request on address
change, disconnect, deadline, partial write, reset or rejected acknowledgement.
A correlated address-status query handles a missed event; if an asynchronous
event races the query, the event takes precedence over its potentially stale
response. The fixture repeats an unavailable snapshot at one-second intervals
until synchronization or the overall deadline.

Host verification: 12 exchange tests, 7 Network Split tests, 6 time wire/state
tests, 23 existing Hosted tests, and 5 image-audit tests passed. These include
synthetic complete station traffic, stale status response, either ack/result
ordering, unsynchronized polling, expired request, and refusal of 1.4.1 before
Wi-Fi setup. The exchange also compiled to an RV32 freestanding object. These
are not evidence of a physical 2.13.1 peer or actual NTP traffic.

A P4 fixture was built using `tools/build-c6-time-probe.sh`. Its image audit
passed with SRAM/ROM-only operation, CPU1 parked, no linked RTOS/FP, and
103,936 bytes of reserved SRAM. Its physically tested binary SHA-256 is
`848d3ad2359c88f92cd67e580717244da649008a0033298f1554a7d0d0526f82`;
the exact binary and capture are under
`/private/tmp/nihos-c6-time-negative-20261101-4m/`.

The connected P4's factory application partition was 4 MiB, not the 6 MiB
layout used in a previous test. An initial read-only attempt stopped before
writing when the partition check detected this. The next attempt explicitly
validated the 4 MiB layout, checked the full initial flash SHA-256 against that
read-only inspection, backed up and verified all 16 MiB, then ran a C6 1.4.1
preflight and the time fixture. The C6 preflight reported chip 13, version
1.4.1 and the diagnostics extension. The time fixture reported known version
1.4.1, failed phase, zero time results and zero synchronization; its output is
consistent with the version rejection tested on the host. No packet capture
was made, so this does not independently prove the exact transmitted RPC list.
C6 firmware was not updated during this run.

The test restored the affected P4 bootloader and application ranges and verified
all 16 MiB against the backup, SHA-256
`8a6e79cb05c538b6bf77cd7e608a424ef89235dd8404201c4d035bd0de34d321`.
A reset was issued afterward; the restored application's boot was not captured.
The flash backup, raw serial captures, candidate hashes and restore verification
are retained in the private temporary directory above.

Afterward, a comment-only source correction and receipt generation were made,
and the fixture was rebuilt. Its app SHA-256 is
`f1cbeac2bc4fcb0aace04acfb82dcef142c2110059fa4ef00147f543cb4e7bc2`.
A byte comparison against the physically tested app found differences only in
the embedded ELF digest at `0xb0..0xcf` and image checksum/hash trailer; all
other bytes matched. The rebuilt image itself was not run on hardware. Its
receipt is `build/c6-time-probe/receipt.json`.

The C6 2.13.1 time candidate, P4-to-C6 custom RPC, SNTP synchronization,
network-loss handling, recovery to 1.4.1 and CPU/memory savings remain unproven
on hardware. SNTP is unauthenticated. A qualified recovery path is still needed
before the first physical installation of the 2.13.1 candidate.
