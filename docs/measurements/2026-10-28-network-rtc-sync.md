# Public NTP to UTC RTC: physical checkpoint

2026-10-28 JST, based on main `941fbe2`. See
[ADR 0053](../adr/0053-network-time-to-rtc.md).

The same explicit-provider image was tested before and after the user enabled
the AP. Before availability, DHCP was not acquired, no NTP request was sent and
no RTC write was attempted. After availability, the device acquired IPv4/DNS,
resolved `ntp.nict.jp`, accepted one stratum-1 response and wrote/read back UTC
RTC. Raw RTC flags remained 0x25; calendar validity changed from 0 to 1.

| Observation | Result |
| --- | --- |
| Qualified image | `86c785d3fa66dfad1e4ac153e526470b6e8dd157aafb5009088d15bf44f2891d` |
| NTP requests / valid replies | 1 / 1 |
| Stratum / observed software RTT | 1 / 76596 us |
| UTC applied / readback end | 1793158957 / 1793158967 POSIX seconds |
| RTC applied / application errors | 1 / 0 |
| Subsequent valid RTC snapshots | 5, advancing |
| Final display/core counters | {'frames': 1233, 'ticks0': 2018, 'ticks1': 2018} |
| Primary static heap | 63424 B; 48 KiB floor unchanged |
| Foreground network/time Flash | 22226 B, exact allowlist and extent |
| Flash restoration | Verified for all four trials; first 64 KiB unchanged |

The initial unavailable/available pair used image
`714b9d30ae33e1530befeafdbf5b36de83c664ca7c714ae81e262f585b1b0e73`.
A final follow-up invalidates cached ARP after a timeout so a changed router MAC
can be rediscovered without a new DHCP address. That final candidate was also
installed, verified, synchronized successfully and restored; its report is the
primary success result in the table.

The final successful snapshot covers 26.536 seconds of one
warm reset. A separate 25.016-second warm-reset trial
then ran the previously qualified default-device image, with no NTP code. Its
RTC was valid throughout and advanced from 1793158406 to
1793158426, consistent with capture UTC. This proves warm RTC
retention, not battery retention across a cold power cut.

The [aggregate receipt](evidence/2026-10-28-network-rtc-sync/qualification.json)
links five source/image/ELF/log identities and verified restoration. Each trial
retains a selected log, checker report and loader/image audit:

- [Unavailable explicit AP](evidence/2026-10-28-network-rtc-sync/explicit-unavailable/report.json)
- [Unavailable saved AP](evidence/2026-10-28-network-rtc-sync/saved-unavailable/report.json)
- [Public NTP and RTC success](evidence/2026-10-28-network-rtc-sync/explicit-online/report.json)
- [Final candidate NTP/RTC success](evidence/2026-10-28-network-rtc-sync/final-online/report.json)
- [No-NTP warm retention](evidence/2026-10-28-network-rtc-sync/no-ntp-warm-retention/report.json)

Selected logs use LF and omit network address records. Complete raw captures,
source archives, generated credentials, firmware and Flash/NVS backups remain
private; their exact hashes are retained independently. Runtime sources match
the successful candidate; later test/evidence additions do not relabel another
binary as the measured image. No raw PCM or nearby BLE identities are recorded.

Each trial rediscovered ESP32-P4 rev1.3 and checked the retained loader bytes,
backed up the full factory app, verified the installed image immediately
before/after capture, restored the prior 1 MiB app and verified the first 64 KiB
unchanged under one exclusive serial descriptor. RTC UTC was intentionally
retained after synchronization; it was not reverted to the invalid old calendar.

Six-hour natural repolling, cold battery/power retention, long-duration drift,
VLF initialization and authenticated time remain unqualified. Existing Wi-Fi
configuration stays private and optional; the public build does not embed this
trial's credentials.
