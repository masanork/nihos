# ADR 0003: Fast static gates and layered emulator tests

- Status: accepted
- Date: 2026-10-25

## Decision

Run a small host-only quality gate on every pull request and push to `main`:

- Zig formatting;
- ZLint v0.10.0 with selected correctness rules and warnings denied;
- ShellCheck for repository shell scripts;
- Debug and ReleaseSafe Zig tests; and
- the C, Zig, and Rust platform-ABI probe.

Pin downloaded tools and verify their release checksums. Keep the ESP32-P4
ESP-EMU smoke as a manually dispatched workflow until the native timer and
scheduler provide stable scenarios worth gating automatically.

## Rationale

ZLint accepts the Zig 0.17.0 source directly and provides useful semantic
checks with negligible runtime for the current tree. Its `unsafe-undefined`
rule also makes initialization and FFI out-parameter assumptions visible to a
reader. The repository opts into a small explicit rule set so analyzer policy
does not change merely because an upstream default changes.

Zwanzig was also evaluated. Its released frontends currently target older Zig
language versions, and the initial run mixed a valid division-by-zero finding
with naming and generic-function false positives. It is therefore not a gate
now. This can be revisited when its frontend matches the pinned compiler or
when a report-only second analyzer adds enough independent signal.

ESP-EMU exercises the actual ESP32-P4 target image and both cores, catching a
class of errors that host tests cannot. It does not model the complete Tab5
board and must not replace physical qualification. The emulator build uses a
separate ESP32-P4 revision-3 sdkconfig; the physical Tab5 configuration remains
unchanged.

## Evidence boundaries

- Host gate: source, ABI, and data-structure evidence only.
- ESP-EMU smoke: target boot and emulated CPU/SMP evidence.
- ESP-IDF-hosted physical run: real Tab5 hardware evidence, but not proof of a
  native nihOS scheduler or driver.
- Native physical run: required before claiming native hardware ownership.

No layer may silently promote evidence from the previous layer into a stronger
claim.
