# Experimental card reader integration with normal native boot

2026-10-27. Merge card branch `a25ad6a` into normal/native-network main
`1f43a4d` in a separate `codex/tab5-card-main-landing` worktree. The original
card branch and its exact physical candidates remain retained. The dirty
main checkout, book work and active SD qualification were not modified.
Original physical evidence commits are preserved rather than rewritten by
rebase. Exact candidate hashes are in [the JSON receipt](2026-10-27-card-main-landing.json).

## Boot behavior and merge scope

The normal live-console configuration retains its landscape Manyoshu splash,
boot stages, console, keyboard and opt-in Hosted networking. The new card
fixtures are explicitly selected: DISPLAY=8 is a keypad demonstration;
DISPLAY=9/10/11 selects card reading directly, without first showing the
normal splash. USB remains disabled unless requested. This merge does not
add automatic card dispatch or a card application to the normal console.

Conflicts were resolved by sharing the existing display-service module and
its runtime/keypad/pins across card code, preserving the main branch's timer,
interrupt, boot-stage, snapshot and network ownership. The card fixtures keep
their existing portrait timing, credential budgets and terminal erasure.
Public notices use the two-bank implementation from `a25ad6a`; private views
retain their separate stop/wipe/rebuild path.

The card preparation framebuffer is never scanned out. Clearing it avoids
embedding the unused normal splash alongside card font assets, keeping the
unchanged record page within 64 KiB. Card images use ELF load segments when
packing: boot-clock code can introduce alignment padding before `.flash.card`,
which must not become a second image mapping in the same 64 KiB Flash page.
The existing ELF/image audit still checks exact bytes, padding and load ranges.

PIN-free readiness and touch diagnostics use size-oriented native-root code
generation, as networking already does. Card/CCID modules keep ReleaseSafe
code generation. The 48 KiB primary heap minimum, memory pools, Flash windows
and stack limits are unchanged. The keypad pixels/plan are unchanged; its
stale renderer-source fingerprint was regenerated with the real renderer.

## Validation

- Zig Debug and ReleaseSafe host tests; 200 Python tests; format, ZLint,
  shellcheck, network-owner normal/diagnostic codegen and six default RV32
  ELF links/audits passed.
- The real headless normal-boot path passed eight emulator cases: normal boot
  with 0/4/32/64 MiB PSRAM, delayed CPU1, and intentional missing-ready/IPI/timer
  failures. This does not establish optical or physical timing.
- The production image decoder passed synthetic exact-pixel, truncation,
  quota and guard checks, including sanitizer builds.
- Disabled, USB, JPKI, PIN-free card readiness, touch, keypad, card-read and
  card-photo device images passed their ELF/image audits. Full/probe automatic
  readers and the normal splash/live-console image also passed.

| Retained candidate | Primary SRAM heap |
| --- | --- |
| Automatic full reader | 52608 bytes |
| Automatic PIN-free probe | 58240 bytes |
| Existing card-photo profile | 50560 bytes |
| Normal splash/live-console profile | 90880 bytes |

Two initial emulator attempts exposed capture issues rather than a wrong
guest timeout: matching only the failure prefix truncated the UART reason,
and echoing a complete exit marker made the checker count the host diagnostic.
The runner now waits for complete lines; the checker ignores that host echo.
A regression proves the echo cannot substitute for missing guest evidence.
Failed captures/builds remain retained. USB CI now includes normal boot/failure
execution and the normal splash/live-console build alongside card profiles.

## Remaining device gates

No merged candidate has been flashed, and no credential was submitted during
integration. Earlier My Number portrait/read/erase results remain scoped to
their original exact candidates. The new public-notice insertion/removal and
reader-reconnect behavior still needs device metadata plus optical confirmation
before PIN testing resumes. New licence profiles, actual change-file encodings
and real issuer-signature verification remain unqualified. The default issuer
key bundle is empty; unknown-key is never reported as a trusted match.

Build artifacts and raw successful/failed logs are retained privately under
the dated Codex evidence directory. Host models, audited images, emulator
execution, CI and physical observations remain separate evidence classes.

## Concurrent main update

Main advanced to `0f573cd` while PR #7 was prepared, adding default connected
Tab5 builds, BLE discovery and board-device/RTC bring-up. That commit was
merged into the landing branch as a second merge, preserving both provenance
entries and adding the shared RTC module dependency. The default connected
build and the automatic full reader passed fresh image audits; Debug,
ReleaseSafe, 200 Python cases and static/six-link gates also passed again.
Their new candidate hashes are recorded separately in the JSON receipt rather
than replacing the initial integration evidence. USB CI explicitly checks
both the network-disabled splash/live-console configuration and the new
default connected build. No hardware was accessed for either merge.
