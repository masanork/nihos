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
