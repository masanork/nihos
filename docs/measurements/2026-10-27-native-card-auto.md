# Automatic card reader: host and build evidence

Implementation: `4f8d6b1d2cd6ac1797a76e4fe79bc8f7e4d3c219`.
Exact candidate hashes and scope are in
[the machine-readable report](2026-10-27-native-card-auto.json).

The host Debug and ReleaseSafe models passed, including classification of
both/neither AID, stale PIN sessions, unknown outcomes, changed/last/blocked
counters, independent one-use PIN budgets, failed cleanup and erasure. The
maximum supported field layouts with a synthetic portrait fit the existing
SRAM scanout pools. The Python evidence-checker suite passed 141 tests.
Format, ZLint, shellcheck, the card RV32 object and six default native RV32
links/audits passed.

Both DISPLAY=11 images passed the full native device image audit:

| Candidate | Authentication | JIS table | Primary SRAM heap |
| --- | --- | --- | --- |
| Full reader | One local submission per PIN | 17,672 bytes | 51,072 bytes |
| Detection only | No credentials accepted | Not linked | 54,144 bytes |

The existing DISPLAY=10 My Number photo image also rebuilt and passed its
image audit. These are compilation results; no claim of a physical regression
pass is made.

Frozen local candidates are `build/card-auto-full-candidate` and
`build/card-auto-probe-candidate`, with ELF, application/boot images, options,
linker layout, source/codec manifests and artifact hashes. The host/build logs
use `build/license-*`. The full and probe candidates have not been installed.
No USB serial port was visible during the final device discovery.

Remaining physical checks are PIN-free classification of each real card,
PaSoRi GetSlotStatus removal/insertion behavior, a held-card negative check,
local PIN1/PIN2 entry on a conventional licence, portrait/basic-field optical
confirmation, removal/tap erasure and a My Number regression on this exact
automatic image. Begin with the detection-only image. Do not infer these
results from the earlier My Number firmware's successful optical observation.
