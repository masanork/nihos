# Normal touch identification and idle coexistence

2026-10-28 JST, runtime commit `aa1fa4e`. This is a partial physical checkpoint:
no contact report or operator view confirmation was received, so it does not
qualify tap/release handling, button operation or touch responsiveness.

The exact connected candidate
`2cbb530b12a4b41bca58f40744bdccbe9f06996e8e5341985d0cffa4ba59486b`
ran for 600.023 seconds under one exclusive serial descriptor. The existing
loader and partition bytes were checked before writing. All 424 archived source
files match the runtime commit, despite the original build receipt identifying
the preceding dirty worktree. Candidate bytes were verified before and after
capture. The full saved app was restored and verified; the first 64 KiB stayed
unchanged.

| Observation | Result |
| --- | --- |
| Controller identification | ST7121, panel 3, 720x1280, 10 slots |
| Normal UI capability | serial+touch, mask 17; control bounds reported |
| Touch polls / fresh reports | 17250 / **0** |
| Touch errors / overflow | 0 / 0 |
| Maximum touch work | 2453 us, identification/idle only |
| Contact/action/optical proof | **Absent; still required** |
| Wi-Fi | One acquisition, no reconnects or service failures |
| NTP / RTC | First response succeeded; UTC write/readback and advancing RTC |
| Finite speaker | DMA end, codec shutdown, stopped and returned storage |
| Finite microphone | Capture, codec shutdown, stopped, returned and erased PCM |
| Internal UART | 64-byte matched loopback, DIR low, stopped |
| Shared I2S workspace | 1536 bytes, final owner/pinned state 0 |
| Display / both harts / IMU | Counters continued; no board/IMU errors |

The [service report](evidence/2026-10-28-normal-touch-idle/service-report.json)
uses the existing finite audio/microphone/UART and NTP/RTC checkers on the same
full capture. The new normal-touch checker deliberately rejects this capture
because no fresh contact reports were observed. Absence of reports without
confirmed physical touches is not evidence that touch handling is defective.

The [qualification receipt](evidence/2026-10-28-normal-touch-idle/qualification.json),
[retained-loader audit](evidence/2026-10-28-normal-touch-idle/image-audit.json),
[commands](evidence/2026-10-28-normal-touch-idle/commands.json) and
[serial excerpt](evidence/2026-10-28-normal-touch-idle/serial-excerpt.log)
retain identities and selected observations. The excerpt includes the first
and last two records per selected marker and is not the full hashed log. Full
logs, credential-bearing firmware and backups remain private in
`build/touch-qualification/attempt-01/` in the qualification worktree.

`python3 tools/check-native-touch.py CAPTURE REPORT` checks image/ELF/options,
source archive and restoration identities, fresh down/up records, accepted
alternating touch view actions, controller/queue errors and continuing
display/hart/board/IMU work. It reports whether all quadrants were observed;
it does not substitute serial counters for optical or negative-gesture proof.
Five new host tests reject missing release, fake view actions, faults,
malformed/mixed logs, changed artifacts/source archives and missing restoration.
The full Python suite passes 243 tests, including the three retained standalone
touch-receipt tests.

Before marking this change ready, repeat with an operator present for visible
LOGS/SPLASH taps, four quadrants, outside/hold/drag/multiple-contact checks and
fresh-report timing under the same connected workload. Other panel variants,
cold cycling, acoustic quality and external RS485 remain separate gates.
