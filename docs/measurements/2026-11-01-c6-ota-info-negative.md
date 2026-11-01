# P4 C6 OTA info diagnostic: first physical attempt

On 2026-11-01, Tab5 ran the P4-only guarded OTA-info diagnostic built from
commit `e781899f`, app SHA-256
`6729016d0e8732e9d10ad579af2cc9b8ba0431753e73598e13a957b771609299`.
The P4 identity and security were checked under the device write lock and
kernel-enforced serial lease. Before installation all 16 MiB of P4 flash were
backed up and verified. After the bounded capture, the P4 flash was restored
and verified against backup SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.

The candidate printed its P4 boot and ROM ABI lines but no OTA-info report or
trap within the 60-second capture. Capture SHA-256:
`93e902c1c946b1bca4531bcd418915f3c23b6f20f249622409bb8ac3a5347db4`.
No claim is made about whether the diagnostic request reached the C6, the C6
firmware version, the cause of the stall, or an unregistered-service response.
The C6 was not updated. The diagnostic source's guarded stream rejects all
OTA write and activation requests, as tested on the host. Raw capture and
backup are private in `/private/tmp/nihos-c6-ota-info-negative-20261101/`.

The restored P4 was reset but its application boot was not captured. The next
candidate adds bounded progress markers to distinguish power, SDIO setup and
RPC exchange; it needs its own identity-matched physical run.

The marker-enabled candidate at commit `eda044d5`, app SHA-256
`6949d4e6b30f5415dc62fbddbb056dd176a126419a7419efeaf637c2a2c07`, was
retried with the same full-flash backup verified against the current device.
It printed stages `0` and `1` but did not reach stage `2` or produce a result
before the 60-second limit. Its capture SHA-256 was
`95c7394fa50337899722d54a6c0cfec28b1826088cc188e27a8c5c9c9fe171b5`. The P4 flash was restored and verified again.
The current timer API's `configureOneShot` leaves the timer stopped, and the
probe was missing `clock.start()`. The stage evidence is consistent with the
resulting stopped-clock delay in power setup; it does not independently prove
that no other issue exists. Several other C6 fixture entry points also call
`configureOneShot` without `start`; this experiment fixes the new info probe
only, and the other entry points need separate correction and validation.
