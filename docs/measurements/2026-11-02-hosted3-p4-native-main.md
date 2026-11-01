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

## Full default profile build comparison

With the public default device profile (XY, normal storage, SQLD, camera and
devices enabled) plus `NIHOS_C6_TIME_OFFLOAD=1` and IPv6 disabled, the
link failed: `.flash.time` exceeded the boot Flash region by 3,826 bytes,
`.flash.pmp` by 6,558 bytes, and the SRAM heap was below the 48 KiB minimum.
The same build on unmodified base main `1a3310ea` also failed: the respective
Flash overflows were 3,544 and 6,270 bytes and the same SRAM minimum failed.
Thus this is an existing default-profile constraint, with this branch increasing
the reported Flash overflow; neither build is a usable image. No default-profile
image was written to Tab5. The separately tested network/device/RTC profile
above linked and passed its image audit.

### Flash placement follow-up

The preceding failures were measured before the foreground-placement change.
An isolated diagnostic link measured the standard (time offload disabled)
heap at 48,960 bytes on base main and 48,832 bytes on this branch, both below
the unchanged 49,152-byte minimum. Network start/retry and stop processing
were then placed in the already mapped XY Flash window when XY is enabled.
The Hosted station and foreground IPv6 routines use that window in the full
XY/C6-offload profile, freeing the boot Flash page as well. The image audit
explicitly checks allowed functions and requires the entire Hosted station
set to reside in one approved window.

With these changes, both the standard default profile and the default profile
with C6 time offload and IPv6 disabled built and passed the native image audit.
Each reported a 49,728-byte primary heap. These are build/audit results: the
full default profile has not been run on hardware, and the diagnostic link
with a temporarily relaxed heap assertion was never a product candidate.

### XY-enabled physical smoke after placement change

A separate Tab5 run exercised clean source commit
`47f4fa45703a0dadc9cb1f376b6aa24e1bd35cbb` using native app SHA-256
`3d225b2108127c8eaa9472e7268feefb5053235c87b8ced0ed4dfe66df3ea529`
and loader SHA-256
`121a7bef14eed3bb162d9ff45bdcbfb075eac7e8e8902234104ec627c933331e`.
The network, devices, XY and C6 time offload were enabled; normal storage,
SQLD, camera and IPv6 were disabled. The 3,897,600-byte app fit the existing
4 MiB factory slot, and the installed partition table was preserved. The
candidate passed its image audit with a 53,056-byte primary heap.

The P4 reported XY ready with persistence disabled, one C6 time reply, one
successful RTC update, and zero reported RTC failures. The time sample was
Unix `1793569024` (2026-11-01 21:37:04 UTC); later valid RTC readbacks
advanced from 21:37:13 to 21:37:19 UTC. BLE reported seven commands, 16
advertisements, zero malformed events and zero timeouts. UI and both core
counters advanced. This is a short foreground smoke, not a test of reconnect,
XY input or persistence, or the complete default profile. C6 version is based
on the preceding OTA/descriptor observation; no version or flash readback was
captured in this run. SNTP remains unauthenticated.

The P4 16 MiB backup and full restoration were verified against SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.
Raw capture SHA-256:
`cd49b121d2d177e4ca891cebb7d202bbb56dc2e5eda0b1090af9049093cf4f9e`.
Raw artifacts remain private in
`/private/tmp/nihos-hosted3-main-xy-rtc-20261102/`. The original P4 app was
reset after restoration but its boot was not captured; the RTC was left set.
