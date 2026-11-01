# C6 time candidate: OTA preparation and P4 simulation — 2026-11-01

This records an actual P4 run with an in-memory OTA responder, plus host and
build checks. **The C6 time firmware was not installed.** The simulated transfer
does not demonstrate a C6 2.13.1 boot, NTP, or a working recovery path.

## Explicit upgrade and recovery fixtures

The one-shot P4 OTA session can now require a specific starting peer version;
a mismatch fails before the user-token gate and before OTA Begin. The time
upgrade fixture requires C6 1.4.1 and contains exactly the time candidate SHA-256
`7f036e616df4d4782015caf30f185f7859af115438f394463600d0f8d69995be`.
It checks the mapped SHA at runtime, emits the observed starting version before
its start gate, and after the transfer checks for an observed 2.13.1 peer. The
post-update version alone is not firmware identity, service health or NTP proof.
Build-only P4 upgrade app SHA-256:
`a722899c7eff0554a2b1af68b159f6cec9e4a7f471c4b22459a20beee75d8265`.

The separate recovery fixture requires C6 2.13.1 and contains only the 1.4.1
C6 diagnostics candidate SHA-256
`0ab00183efb3149b568d0968877f1a7718f7c79817748a8e5c0417957cbf5e3b`.
Build-only P4 recovery app SHA-256:
`bcc137e94d99ff3a103497b459569778c4f90d7df0031bb6a63707edca0ab2a7`.
Neither image has been physically executed. In particular, the 2.13.1 -> 1.4.1
path is still unproven and depends on 2.13.1 booting, establishing Hosted, and
serving OTA. It is not an independent rescue path for a nonbooting C6.

The C6 2.13.1 source conditionally checks that the first write contains the
288-byte image/segment/application descriptors when built with IDF 6.1 or
later. The present IDF 5.5.2 candidate compiles this specific check out. The P4
implementation conservatively requires a long enough image and its 384-byte
first write covers these headers regardless.

## P4 simulation on Tab5

The simulation P4 app, SHA-256
`8285903bd11fbaee06fb9e274f343ea2325bb8c9beaa251cb780967dd6d4cb2f`,
contained the exact 1,278,048-byte time candidate. Its physical Hosted stream
was wrapped to reject OTA Begin, Write, End and Activate; the image transfer ran
against a P4 memory-only responder that validates each sequential chunk. The
P4 reported the reviewed mapped hash, `NIHOS_C6_OTA_SIMULATED`, a 1.4.1 origin,
and 1,278,048 acknowledged simulated bytes. Following the simulation, a new
physical handshake still reported C6 1.4.1 with the diagnostics extension.
This is not C6 flash readback and the wrapper/source contract, not a packet
capture, is the evidence for blocking OTA commands.

The capture SHA-256 is
`5185697fe8056238d2ce8b6d8fa8df151f32263267edf88fca743db4cab74870`.
The separate actual-upgrade evidence checker explicitly rejects this capture
because it contains the simulation marker.

Before running, the script took the writer lock, claimed serial exclusively,
checked P4 identity/security and the current 4 MiB app partition, and backed up
and verified all 16 MiB. Afterward, it restored the affected P4 spans and
verified all 16 MiB against the backup SHA-256
`80fef2c6803dde580d6cb6dbb64d2e8ff8666a4b0ba53f8d8e0c10e7b40b30d5`.
The restored P4 was reset; its application boot was not captured. Logs, exact
P4 app bytes, backup and restore result remain under
`/private/tmp/nihos-c6-time-ota-simulation-physical-20261101/`.

## Other verification and remaining boundaries

Host tests checked origin mismatches before Begin, full candidate-sized
in-memory transfers under both 1.4.1 automatic activation and 2.13.1 explicit
Activate, rejected/lost/error paths, and rejection of synthetic invalid or
simulated evidence. Actual generated 2.13.1 protobuf-c independently matched
Begin, Write, End and Activate request vectors. The patched upstream Activate
handler's host harness again reproduced the original invalid-state negative
control and passed with the correction.

Actual 1.4.1 -> 2.13.1 installation, post-boot CustomRpc/NTP, 2.13.1 -> 1.4.1
recovery, and independent C6 unbricking remain unverified. Activation response
loss can leave the selected boot slot uncertain; do not blindly replay. Neither
a version string nor a build, simulation, or OTA acknowledgement proves the
running C6 flash bytes or application health.
