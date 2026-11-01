# P4 mapped read probe for C6 OTA candidate

This is a P4-only finite image-mapping test, not a C6 OTA update. The P4
candidate contains no C6 driver, firmware update code, or C6 reset request.
A mapped read-only segment contains the C6 diagnostic application image.
The P4 computes SHA-256 from mapped bytes and prints the result.

- C6 app: 1,079,120 bytes, SHA-256
  `0ab00183efb3149b568d0968877f1a7718f7c79817748a8e5c0417957cbf5e3b`.
- P4 app: 1,144,736 bytes, SHA-256
  `61e3d08492ef5a9d60c775c02668d33a8e07d3a57bfa7e59d43e13c24d336d60`.
- Build audit: two read-only flash sections, mapped candidate bytes identical
  in ELF and image, executable code and data in P4 SRAM, no FP/RTOS, image
  digest valid. The C6 image starts at virtual address `0x40010024`.
- Physical: under the existing board writer lock and verified exclusive serial
  lease, identify P4 rev 1.3 / MAC, check security, read and verify full 16 MiB
  P4 flash, check factory partition layout, write and verify P4 loader and app,
  warm-reset and capture. Runtime reported `bytes=00107750` and the candidate
  SHA-256 above. Exact P4 image and partition bytes were verified immediately
  before capture. No C6 command or OTA request was sent.
- Restore: original P4 loader and the entire affected app span were restored;
  `verify_flash` against the full 16 MiB backup passed. Backup SHA-256
  `72375a7e60e8202d2b9341be75dae6b534b74237a1b10c8931b147a680bac293`.
  Warm reset was issued; restored firmware boot output was not captured.

Evidence: private capture directory
`/private/tmp/nihos-c6-map-physical-20261101-escalated/`, including
`capture.log`, `result.json` and `restored.json`. Flash backups may contain
private data and are intentionally not committed. The capture qualifies only
this P4 read probe and this candidate; it does not establish OTA transfer,
C6 boot after update, C6 partition layout, recovery or network behavior.

## C6 handshake preflight attempts

A subsequent exact P4 candidate combined the mapped-image hash check with an
exclusive Hosted 1.4.1 handshake, stopping before the first OTA Begin step. The
first attempt trapped after the image hash. Its RV32 disassembly showed the
preflight function allocating 12,608 bytes on the 8,192-byte CPU0 stack while
constructing the session by value. P4 flash was restored and verified.

The session was changed to initialize directly in static storage. Its compiled
preflight frame fell to 2,576 bytes (not a complete call-chain stack bound). The
second exact candidate printed the correct mapped hash and then reported
`status=0 error_code=0x13`; the error was not yet named by that candidate. It
sent no OTA Begin. The exact P4 flash was again fully restored and verified.
Capture/restore evidence is in the private directories
`/private/tmp/nihos-c6-ota-preflight-physical-20261101/` and
`/private/tmp/nihos-c6-ota-preflight-physical-20261101-retry/`. Failure to
complete the handshake is not evidence that C6 OTA is unsupported.

A diagnostic candidate reported `Controller` during `enableFunction` at SDIO
CMD52, raw interrupt `0x100` (P4 candidate SHA-256
`f4524ff29d5771a22ae6a7aa191671c3cf1d86b803c5481224514af009ada1a7`).
ESP32-P4 SDMMC register definitions identify bit
8 as response timeout. This is before the Hosted version handshake and before
OTA Begin; it does not establish that OTA is unsupported. The exact preflight
candidate SHA-256 was independently checked before capture; evidence and full
P4 restore verification are in
`/private/tmp/nihos-c6-ota-preflight-physical-20261101-stage/`.

Between the prior diagnostic run and this last run the observed full P4 flash
baseline changed from SHA-256 `72375a7e60e8202d2b9341be75dae6b534b74237a1b10c8931b147a680bac293`
to `0a21266492da4c6f3e643ce481de3b723948a3871d59216b5d3c53c4e3c80ee0`,
including 974 changed 4-KiB sectors. This last run restored and verified the
latter, independently captured baseline. The cause or writer is not established;
the lock file's recorded task is not proof of current ownership. Treat the
board as concurrently used and do not make further device writes until its
current owner/write coordination is established. The recovered old backup must
not be used to overwrite the newer baseline.

## Reset-settling hypothesis and build-only revision

The earlier main-integration diagnostic recorded the same `Controller` / CMD52
response-timeout pattern on all three warm boots with a 300 ms C6 reset delay.
A later long-DMA diagnostic with a 2 s delay completed Hosted/Wi-Fi startup on
three warm boots. These were different candidates; the delay is a plausible
contributing factor, not a proven cause. Sources and physical logs are in
`/private/tmp/nihos-c6-hosted-diagnostic-main-physical-20261101/` and
`/private/tmp/nihos-c6-hosted-diagnostic-final-20261101/`.

Only the OTA preflight was changed to wait 2 s after C6 reset. Its new P4 app
build SHA-256 is
`c85418524520a316aa2c4d8a858413f3be91d632f14c9e17759cb28aebcc4d4e`;
the mapped C6 candidate remains the same. The image and SRAM audits passed.
This candidate has not been booted, and no C6 OTA has been attempted. The user
confirmed another task is using Tab5, so no further serial or device operation
is permitted until that work releases the board.

## 2-second preflight on physical Tab5

The build-only revision above was subsequently installed under the shared writer
lock and exclusive serial lease, after verifying a full P4 flash backup and the
exact P4 candidate. It reported the exact mapped candidate SHA-256 and
`status=1 stage=6 peer_chip=13 version_known=1 major=1 minor=4 patch=1`. The
probe stopped before OTA Begin; no C6 update was attempted. P4 flash was restored
and the complete 16 MiB matched the immediately preceding backup SHA-256
`0a21266492da4c6f3e643ce481de3b723948a3871d59216b5d3c53c4e3c80ee0`.
Evidence: `/private/tmp/nihos-c6-ota-preflight-physical-20261101-2sec/`.
This is one physical preflight success and does not prove the reset delay was
the sole cause of earlier failures, or that an OTA write or new C6 boot works.

## Update fixture: device gate and host-only transfer checks

The explicit update fixture P4 image SHA-256
`79ccccdbc26582b5608e902657cce9e4009418fbe32cb81f53fac4f3093e79cc`
was checked before one physical warm boot under exclusive writer/serial leases.
It computed the expected C6 image hash, identified the Hosted peer and printed
`NIHOS_C6_OTA_READY`. After a two-second no-command interval, an intentionally
invalid newline was sent. It reported `InvalidToken`, `status=0`, `stage=6`
and `acknowledged_bytes=0`; no Begin/Write/End was requested by this code path.
P4 flash was restored and the full 16 MiB verified against that run's backup
SHA-256 `0a21266492da4c6f3e643ce481de3b723948a3871d59216b5d3c53c4e3c80ee0`.
Evidence is private under `/private/tmp/nihos-c6-ota-gate-physical-20261101/`.
This proves the invalid-start path for that image, not a successful C6 OTA or
boot of the new firmware.

The update-only linker layout keeps the CPU0 and IRQ0 stacks at 8 KiB each;
CPU1 is parked and its unused normal and IRQ stacks are 1 KiB each. The P4
SRAM audit reports 27,008 bytes of remaining heap reservation (floor 16 KiB).
A separate checker verifies all four stack boundary sizes; mutating the CPU1
stack boundary in the ELF was rejected. This structural check is not a full
call-chain stack proof. The user requested no further device access while
travelling, so further work after this run was host-only.

The host pump exercised a synthetic image of exactly 1,079,120 bytes, checking
all bytes and acknowledgements across every 384-byte chunk; it also checked a
lost Write response causes terminal timeout with no retry. This is a transport
model, not device transfer evidence. The C6 firmware has still not been updated.
