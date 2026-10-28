# Connected default-device coexistence and NTP recovery

2026-10-28 JST, using unchanged main `c54d9dd` runtime source in one normal
connected image. This closes the gap between the previous unconfigured-device
exercise and the independent public-NTP/RTC checkpoint. It is not a sustained
network-load, audio-quality or external-RS485 test.

## One image, one capture

The exact image `381779cd61ffa4a1bb5b7f2f0f676e562ab09c2f021b8bc055a41807c826200a` ran for 88.101 seconds
under one exclusive serial descriptor. The [driver checker report](evidence/2026-10-28-connected-devices/devices-report.json)
and [time recovery checker report](evidence/2026-10-28-connected-devices/time-report.json)
refer to the same app and raw serial SHA-256. The [qualification receipt](evidence/2026-10-28-connected-devices/qualification.json)
retains source/archive/ELF identities; the [loader/image audit](evidence/2026-10-28-connected-devices/image-audit.json)
checks the unchanged 48 KiB heap floor and bounded foreground Flash extents.

| Observation | Result |
| --- | --- |
| Wi-Fi session | One DHCP acquisition, zero reconnects/disconnects/service failures |
| NTP | First request failed, one later request succeeded; 2 attempts, 1 reply, 1 retained failure, 0 rejected replies |
| Successful NTP | Stratum 1, observed RTT 105990 us |
| RTC | Valid through all 18 device reports; 1 later network-time application, no RTC errors |
| Microphone/audio overlap | Both conflicting requests rejected before changing ownership |
| Audio/microphone sequence | mic → audio → mic; all finite DMA/codec/erasure cleanup checks passed |
| UART loopback | Two internal 64-byte exchanges; exact replies, DIR low and controller stopped |
| Shared I2S workspace | 1536 B after first request; reused, final owner/pinned state 0 |
| Primary static heap | 63424 B |
| Final UI/hart counters | {'frames': 5134, 'ticks0': 8522, 'ticks1': 8522} |
| Board I2C / IMU | Zero board errors; IMU acquisition continued |
| Restoration | Full prior app verified restored; first 64 KiB unchanged |

The [command schedule](evidence/2026-10-28-connected-devices/commands.json)
records the explicit device requests. No external RS485 transmission or raw
microphone PCM was requested or retained.

## Recovery is not hidden as a clean first attempt

The first NTP request was observed in pending phase 4, followed by waiting
phase 1 with one failure and no reply. After the backoff interval, the next DNS
lookup selected another server address and the second NTP request succeeded.
Wi-Fi stayed acquired, other device operations completed, and the already valid
RTC kept advancing during the wait. The RTC application count remained zero
until the valid response and then became one.

The [network statistics](evidence/2026-10-28-connected-devices/network-statistics.json)
retain counters without LAN identifiers. The UI samples preceding observed
failure and observed recovery are ticks 1016 and 7521, respectively:
6505 ticks, approximately 65.05 seconds at the source's
10 ms timer period. These are coarse five-second reporting points, not exact
packet-send timestamps. Exact minimum retry scheduling remains covered by the
host state-machine tests; this capture is consistent with its 64-second policy.

`tools/check-native-time.py --mode recovered-sync` requires the ordered pending,
failed and recovered history, monotonic attempt/reply/failure counters, exactly
one retained request failure, no rejected replies, and no RTC write before the
valid response. It still requires matching UTC application/readback, acquired
DHCP, advancing UI/harts, no board-I2C/RTC errors and exact capture identity.
The default `sync` mode continues to reject this trace; a failed attempt is not
silently relabeled as clean success. Negative controls cover missing history,
extra attempts, hidden failures, early clock application and invalid RTC data.

The [selected log](evidence/2026-10-28-connected-devices/selected.log) uses LF
and omits network address records. Full raw capture, source archive, credentials,
firmware and Flash/NVS backups stay private. The source was frozen before the
capture; subsequent changes add the recovery verifier and documentation only.
No native runtime code changed for this checkpoint.

This observes a stable acquired connection with ordinary background traffic
and two NTP attempts. It does not establish sustained throughput/load, external
RS485 peer/wires, audible quality, optical display correctness, cold power-loss
retention, natural six-hour polling or long-duration drift. See the
[current device inventory](../planning/tab5-native-device-support.md) for the
remaining application/hardware gates.
