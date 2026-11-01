# Hosted 3 with latest-main P4 network and RTC on Tab5

On 2026-11-02 JST, a clean P4 candidate at commit
`a6a12a0ea85e89d2a1509c77bcbde3998f17b871` (3.x changes rebased on main
`1a3310ea80d3aa3376c781f24b239d4c77c85a0e`) was tested with the C6 previously
updated to 3.0.10. The native application SHA-256 was
`f477f482e5ec3c4a34f24f5b90ebef21d6519ef830be8a5eff761f07c5c98d31`;
the loader SHA-256 was
`17742f15033bb4840b97d60f0999698bbc8ae6040722f2376ac4956755b83c9d`.
The full source and artifact receipt was checked immediately before capture.
The native image audit and `zig build test -j2` passed.

The profile enabled native network and devices, C6 time offload and saved Wi-Fi;
IPv6, XY workspace, normal storage, SQLD and camera were disabled. This is the
native network/device/RTC integration, not a full default XY/storage profile.
The capture reported one IPv4 acquisition and zero network failures, one
accepted C6 time result, and one RTC update with zero failures. The update
sample was Unix `1793547367` (2026-11-01 15:36:07 UTC); later valid RTC
readbacks advanced through 15:36:15 and 15:36:21 UTC. The UI frame and both
core tick counts advanced, while BLE reported seven commands, 17
advertisements, zero malformed events and zero timeouts. This capture did not
itself print a C6 firmware version: its 3.0.10 identity comes from the
immediately preceding OTA and read-only observation, and is not a flash
readback. SNTP is unauthenticated and no reference-clock comparison was made.

The exclusive writer and serial locks were held. The entire 16 MiB P4 flash
was saved and verified before installation, and restored and verified after
the observation against SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.
The restored application was reset but its boot was not captured. The RTC was
intentionally left updated; the C6 firmware was not rewritten in this test.
The raw capture SHA-256 was
`a06109924caf49500bfb11e0660826e74d1442d5258bf30ca2b4310f8d478003`;
private artifacts are in `/private/tmp/nihos-hosted3-main-native-20261102/`.

This short test does not qualify power-loss retention, reconnect, prolonged
operation, the full default XY/storage profile, QUIC, iroh, or C6 recovery.
