# C6 time snapshot experiment — 2026-11-01

This records host tests and a C6 build only. No C6 or P4 device was accessed
for this experiment, and neither NTP traffic nor P4-to-C6 CustomRpc has been
observed for this candidate.

The experimental time service initializes ESP-IDF SNTP on C6 and returns
whether this boot has received an SNTP sync callback, Unix seconds, and the
elapsed monotonic seconds since the last callback. Its nonblocking CustomRpc
callback submits to a single-entry worker queue; overflow drops a request, so
P4 must use a timeout. The P4 codec correlates the asynchronous event with a
request ID and generation and rejects expired or stale responses. See
`ports/esp-hosted-c6-time/README.md` for security, reset, and caller contracts.
SNTP is unauthenticated and this snapshot does not establish trustworthy time.
The P4 codec is not yet connected to a real station or application.

Validation:

- C request parser and response encoder passed their host test with warnings as
  errors; six focused Zig tests passed, including matching C/Zig request and
  response vectors, stale generations, deadlines, cancellation and unavailable
  time. These are codec/state tests, not transport or scheduling tests.
- Built for ESP32-C6 with ESP-Hosted 2.13.1 commit
  `0e8d0e3f0c2723deaf15441200cb4d8c53fea230`, ESP-IDF 5.5.2 commit
  `30aaf64524299d3bde422ca9a2848090d1bc5d0f`, and the experimental Network
  Split plus HTTPS integration overlays described in the preceding preflight.
  The temporary source also contains the experimental OTA Activate-status fix.
  This candidate enables `CONFIG_NIHOS_TIME_SERVICE=y`, Network Split and peer
  data transfer, and disables `CONFIG_NIHOS_HTTPS_SERVICE`.
- App size 1,278,048 bytes: 294,816 bytes remain in the 1,572,864-byte OTA
  slot. App SHA-256:
  `7f036e616df4d4782015caf30f185f7859af115438f394463600d0f8d69995be`.
  Esptool verified the image checksum and validation hash. Partition-table
  SHA-256:
  `0241fa0d2e573dee86756e39fb4181e61ff7218087619cab565b602df55954d6`,
  matching the previously compared vendor table. The generated sdkconfig
  SHA-256 is `6b97d7d2f9faed0a1fc31974c3f43d41fdaf90c69fbb44c44c46446e6663ae8f`.
  The build uses the same temporary component-manager parent-PID shim described
  in the preflight. Artifacts, source and log are respectively
  `/private/tmp/nihos-hosted-213-time-build`,
  `/private/tmp/nihos-hosted-213-time`, and
  `/private/tmp/nihos-hosted-213-time-build.log`.

Before a physical test, integrate the P4 caller and observe the 2.13.1 Hosted
handshake and event flow, arrange and qualify a recovery path, and decide the
time acceptance policy. Do not reuse the 1.4.1 update fixture as proof of a
2.13.1 boot or recovery. Measure memory, CPU load and behavior under Wi-Fi loss,
reset, queue saturation and stale replies on the exact candidate before claiming
an offload benefit or operating reliability.
