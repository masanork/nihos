# Hosted 3.0.10 C6 OTA on Tab5

On 2026-11-02 JST, under the P4/C6 write lock and an exclusive serial lease,
the C6 was updated from its reported Hosted 2.13.1 to Hosted 3.0.10. Before
any fixture was installed, the entire 16 MiB P4 flash was backed up and
verified (SHA-256 `06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`).
It was restored and all 16 MiB verified against that backup after the test.
The restored P4 application's subsequent boot was not captured.

The baseline C6 reported chip 13, `network_adapter`, version `2.13.1`, IDF
`v5.5.2`, matching metadata from the previously installed candidate SHA-256
`7f036e616df4d4782015caf30f185f7859af115438f394463600d0f8d69995be`.
This is self-reported metadata, not a flash-byte identity check.

The physically preflighted updater P4 app SHA-256
`8c0ea479992260650377fac6eaecda31b3b0ad63dd94fad4265cf9c0083280b1`
(source `e53c75a571625ef969f6247a828bf7a64cb530fc`) hashed its mapped C6
candidate and reported the expected SHA-256
`04bd14faf943453ccf39075bc61456463b3f362643a3a63dab0f82a53f4dc8fe`.
A single start token was sent. The P4 reported 1,397,104 acknowledged bytes,
successful activation, and a subsequent C6 version handshake 3.0.10. The
[redacted checker output](evidence/2026-11-02-hosted3-ota-upgrade.json)
records the capture digest and checks the ordered output, including rejection
of simulated captures. No independent packet capture or C6 flash readback was
performed.

A separate read-only 3.x query reported project `eh_cp_wifi_sta`, version
`v3.0.9-90-g4e02944-dirty`, IDF `v5.5.6`, 4 MiB flash, running and boot
partitions at offset `0x190000`, size `0x180000`, and next update partition at
`0x10000`, size `0x180000`. It reported running OTA state `0xffffffff`,
secure boot false and flash encryption false. These are the running C6's
reports, not independent examination of its partition table or eFuses. A
conditional 3.x-to-2.13.1 Hosted OTA recovery fixture was built, but was not
run. Independent recovery and automatic boot rollback are unverified.

The first post-update time fixture observed 3.0.10 and station connected,
but failed before issuing the time request: its status query arrived while
link was up and DHCP/DNS were not ready, a partial state rejected by the P4
parser. Thus this run does not establish time synchronization. Raw logs and
the P4 backup are private under `/private/tmp/nihos-hosted3-real-upgrade-20261102/`.
The restored P4 app is the user's original app; this run does not deploy the
3.x P4 integration to the user's normal firmware.

## Time retest after the P4 DHCP fix

The P4 Network Split decoder was changed to accept the observed link-up,
DHCP/DNS-down, zero-interface-address snapshot as not ready, invalidating an
old address rather than adopting a partial one. Unit tests cover the exact
observed wire response and the address-generation revocation. Hosted split
and time exchange tests passed (10 and 19 tests respectively).

In a separate lock-held run, P4 fixture source commit
`7488bd6b1331c2d60c422d764086c519fed3b3fa` and app SHA-256
`7aeece2aa82fb6bfcb073840c8e5e1cb7992d12d1a8ee66aa7af1a67556a6860`
were used. The fixture reported C6 3.0.10, station connected, a complete
split address, an acknowledged request, and a synchronized C6 result. The
reported sample was Unix time `1793547026` (2026-11-01 15:30:26 UTC), with
reported age zero. This is unauthenticated SNTP and was not independently
compared with a reference clock; it does not establish P4 RTC persistence.
The [redacted result](evidence/2026-11-02-hosted3-time-fixed.json) includes
the exact report and capture SHA-256. The P4's full 16 MiB was backed up,
restored and verified again against the same digest; its restored boot was not
captured. This run sent no C6 OTA request. Raw evidence remains in
`/private/tmp/nihos-hosted3-time-fixed-20261102/`.
