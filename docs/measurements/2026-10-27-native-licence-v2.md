# Licence reader v2: qualification boundaries

Source: `3e685862afe26faa78be5281ad9aca9637938687` on
`codex/tab5-card-service`. Exact candidate fingerprints, input specification
hash and scope are in [the JSON report](2026-10-27-native-licence-v2.json).

Implemented profiles are conventional IC driving licences and the My Number
licence AP, with separate local PIN namespaces, dated change records and
external-key signature verification. Original My Number four-field/portrait
reading remains a separate selectable job. The default issuer-key bundle is
empty; real-card signature verification has not been qualified.

## Completed software checks

- Zig Debug and ReleaseSafe host models passed. Coverage includes fixed EF
  lengths, PIN counter changes/last attempts/unknown outcomes, stale sessions,
  one-use wire budgets, cancellation, cleanup failure and workspace erasure.
- Synthetic signatures under exponents 3 and 65537 passed. Modifying original
  common fields, domicile, portrait or final padding failed verification;
  generic DigestInfo and malformed padding were rejected. Change EF04 remains
  outside the signed scope and is labelled accordingly.
- Literal RFU tag FF is distinguished from the extended photo tag. Whole-file
  tag formats must be unambiguous, and WEF02/WEF03 formats must agree.
- All 11336 compressed glyphs matched their original bitmap pixels in both
  Python and Zig. Synthetic overview/history layouts and a ten-attempt PIN
  display fit the existing scanout pools.
- The Python suite passed 145 cases. Format, ZLint, shellcheck, card RV32 object
  compilation and six default native RV32 links/audits passed.

All three exact device candidates passed their full ELF/image audits:

| Candidate | Reader mode | Primary SRAM heap | Installed |
| --- | --- | --- | --- |
| Full | Local read; one submission per PIN | 50048 bytes | No |
| Probe | Application classification only; no credentials | 55168 bytes | No |
| Legacy DISPLAY=10 | Existing My Number portrait flow | 49536 bytes | No |

The 48 KiB heap minimum, two mapped segments, 640 KiB optional Flash window,
display pools and codec's 12 KiB SRAM stack were retained. The crypto stack is
a separate guarded 64 KiB area inside the existing task-owned external lease.
Its physical high-water/erasure observation remains pending.

Earlier builds exposed a Flash-capacity excess and a legacy SRAM-layout
regression. Lossless font encoding and shared foreground code resolved the
capacity issue. Explicit compile-time renderer selection and opt-in diagnostic
fields restored the legacy heap. Failed logs and diagnostic-only ELF files
were retained; diagnostic layouts were never installed or treated as passes.

## Physical state

The USB serial port reappeared during this work. A 256-byte application-header
read identified `nihos-c6-probe`, matching another worktree's active C6 network
evaluation. Identification reset the device once; no card image was written.
The read-enabled, probe and legacy candidates above are all retained locally.

Real insertion/removal behavior, the held-card negative check, both licence
PIN responses, actual tag encoding, portrait/basic-field optical confirmation
and on-device result erasure remain pending. Start with the probe candidate
when the Tab5 is available for this work. Official public keys must be obtained,
pinned and rebuilt before a real issuer-signature match can be claimed. Host,
build, synthetic UI and the earlier firmware's optical result do not establish
these physical outcomes.

## Synthetic UI review

These are host renders with fictional fields and a generated color pattern,
not photographs of the device or real card data:

- [Conventional licence overview](2026-10-27-licence-v2-synthetic-classic.png)
- [My Number licence overview](2026-10-27-licence-v2-synthetic-myna.png)
- [Dated change history](2026-10-27-licence-v2-synthetic-history.png)

Frozen candidates are `build/licence-v2-release-{full,probe,legacy}`. Each has
the exact source commit, ELF/application/boot images, options, linker layout,
source/codec manifests and an artifact-hash receipt. Private copies and failed
attempts are retained under
`~/Documents/Codex/2026-10-27/nihos-licence-v2-3e68586/`.
