# Hosted 3 Network Split UDP: initial single-attempt observation

On 2026-11-02 JST, a Tab5 with the C6 previously observed as Hosted 3.0.10 ran
the separate CPU0 P4 diagnostic from clean commit
`9f908dd4c56617335bbf0b2d7309018ef80a8e01`. The P4 app SHA-256 was
`aaf297434c06f853b32fcb56e0d06ec280a449a8e3c05ebffb5adf320c90224a`;
the build audit reported 18,240 bytes of unused primary SRAM heap. The fixture
used C6-owned Network Split DHCP and sent one 1,254-byte Hosted frame containing
one 1,200-byte UDP payload. Its report identified chip 13 / Hosted 3.0.10 and
one completed P4 send; the P4 did not report an echo and ended in stage 7
with error code 25. The numeric error code is not independently decoded here.

An independently bound Mac UDP receiver observed one matching 1,200-byte
payload from the P4-reported IP and expected source port, SHA-256
`159b51633f1b15bf03362c09e230dc0fab18819b624f445e279959e4452b688c`, and
reported sending a 1,200-byte echo. P4 receipt of that echo was not observed.
This establishes one-way device-to-peer payload delivery for this run, not
round-trip success, loss rate, general UDP, QUIC, TLS or iroh interoperability.

The installed candidate's SDK configuration maps P4 UDP ports to 49152–61439
and defaults unmatched ports to the C6. The fixture used source port 44444,
so the return echo's destination was outside the P4 range. This is a plausible
explanation, not an observed packet-routing trace; use a host-range source port
in a separate attempt. The candidate was not altered after its receipt check.

The P4 writer lock and exclusive serial lease were held. All 16 MiB of P4 flash
were backed up and verified before the fixture and restored and verified after,
against SHA-256 `06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.
The C6 firmware was not rewritten; the restored P4 boot was not captured.
Mac peer identity was independently rechecked immediately before installation,
because the firmware-tool Python process saw a different MAC under macOS
privacy rules. The private device capture SHA-256 was
`96598bf3970c4a37a06a164aed5f8f486cb3bfb5c9c0ba4d9be31cf704fbd7ad`;
private raw data is under `/private/tmp/nihos-hosted3-split-udp-physical-20261102-v2/`.
