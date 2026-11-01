# Hosted 3 P4 compatibility: existing C6 physical check

On 2026-11-01, Tab5 ran a P4 image from clean commit
`1418f0d8` with the Hosted 3 negotiation changes, while the existing C6
application was left untouched. The P4 app SHA-256 was
`a449a51497efa33ed41bccd45bf29c00ee9a88e407c1e482189614fd8b4098b6`.
The image used the opt-in C6 time offload, C6-saved Wi-Fi configuration and
IPv4. The app and loader were identity-checked, the P4 MAC and silicon revision
matched the expected Tab5, and a write lock and kernel-enforced serial lease
were held. The complete 16 MiB P4 flash was backed up and verified before
installation, and restored and verified afterward against backup SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.

The P4 reported one network acquisition, no reconnects or network failures,
and a successful RTC update from the C6 time service. Two valid RTC readings
after the update advanced from 13:47:05 to 13:47:11 UTC with no reported RTC
error. BLE reported seven commands and 15 advertisements without malformed
events or timeouts. The capture SHA-256 is
`19a24befdd6498ff56363d0e6bc1b26ddfcbb0f3fcf554c373089c6a72bb5511`;
the raw capture and full backup are private under
`/private/tmp/nihos-hosted3-p4-legacy-20261101/`.

The previous experiment identified the installed C6 application as custom
Hosted 2.13.1; this capture did not independently print or read back the C6
version. The successful time path accepted the negotiated peer, but this is
not a C6 flash readback. It is evidence for this P4 binary with the existing
C6, not for a 3.0.10 C6, rollback, iroh, QUIC, or the later OTA changes.
The restored P4 application was reset but its boot was not captured. The RTC
was intentionally left set. SNTP time is unauthenticated.
