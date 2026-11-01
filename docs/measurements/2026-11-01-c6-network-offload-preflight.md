# C6 Network Split and OTA compatibility preflight — 2026-11-01

This is build and host-test evidence, not a C6 Network Split, NTP, HTTPS,
2.13.1 OTA, or recovery run. The installed C6 was left on the 1.4.1
custom-diagnostics firmware after the [post-OTA Wi-Fi/BLE smoke](2026-11-01-c6-post-ota-connectivity.md).

## OTA version boundary

The running peer controls the OTA protocol: 1.4.1 activates at End, whereas
2.13.1 requires Activate after End. The client has a separate opt-in path for
2.13.1, and the ordinary update fixture continues to accept only 1.4.1. Host
tests exercise both sequences, negative responses, short-image rejection, and
blocking Activate in the non-writing simulation. The independently generated
2.13.1 protobuf-c request matches `0801108a02180cd21000`.

A separate P4 recovery fixture targeting the existing 1.4.1 diagnostic app was
built with 2.13.1 explicitly enabled. Its P4 binary SHA-256 is
`218b684277d70a161476aa4c57d71114b36dd25dd4be59e3027866c522fc72c7`.
It is an experimental write-capable image, not a demonstrated recovery path;
no 2.13.1 peer or physical downgrade was tested. It must not be treated as an
independent means of recovery until its whole path is proven.

## Candidate build and activation defect

For ESP-Hosted 2.13.1 commit `0e8d0e3f0c2723deaf15441200cb4d8c53fea230`
and ESP-IDF 5.5.2 commit `30aaf64524299d3bde422ca9a2848090d1bc5d0f`, a
Network Split / HTTPS candidate was built with the experimental activation
status correction applied. The candidate app is 1,477,408 bytes in a
1,572,864-byte slot, leaving 95,456 bytes; its SHA-256 is
`2cf18949d8b962fea5672ac4eb9ad4271266c1e290366f204b56eb688e9d52b6`.
The partition-table SHA-256 is
`0241fa0d2e573dee86756e39fb4181e61ff7218087619cab565b602df55954d6`,
matching the previously compared vendor partition table. The build sdkconfig
SHA-256 `3398c52c8b63017527dbe049df20737d6041b95c0f8c2bf617cfcbac9e144f9f`
matches the preceding HTTPS candidate. Artifacts and log are under
`/private/tmp/nihos-hosted-213-activation-managed-build` and
`/private/tmp/nihos-hosted-213-activation-managed-build.log`.

The upstream handler could return success for invalid OTA states without
activating; the patch and source-extracting negative-control harness are in
`ports/esp-hosted-c6-ota-activation`. That patch was applied to this build's
temporary source copy, but is not automatically integrated into the older
HTTPS overlay. Even with it, a lost response or an error can leave the boot
partition selection uncertain; do not automatically replay Activate. A
successful response does not establish the newly selected firmware booted.

The managed build used a temporary Python shim for the component manager's
parent-PID lookup because sandbox process inspection was denied; it used the
manager's documented parent-process fallback and did not change ESP-IDF source
or the sdkconfig. Neither the candidate nor this fixture was flashed. SNTP in
the HTTPS candidate is part of its HTTPS service and is not yet a tested,
standalone P4 time service.
