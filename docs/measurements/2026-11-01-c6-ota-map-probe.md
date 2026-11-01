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
