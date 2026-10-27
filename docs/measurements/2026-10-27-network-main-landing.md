# Native networking main landing preparation

2026-10-27. Land the qualified native P4 prerequisites first, then the opt-in
factory-Hosted network owner. The original working trees and the exact
physical candidates remain retained separately.

## Review boundaries

- Prerequisite: `codex/native-baseline-main`, based on the existing verified
  display/console, memory and read-only storage work plus remote main. Only
  the two previously identified static-check corrections were added.
- Networking: `codex/c6-network-main`, replaying the thirteen networking commits
  while excluding the unrelated book-draft commit. The book's 17 files remain
  in their original branches/worktrees and are not part of this landing.
- The original dirty main worktree was not reset, rebased or overwritten.
  Other active USB/VFS/memory branches are not included by this procedure.

## Automated checks

The prerequisite passed 213/213 Debug and ReleaseSafe tests, 163 Python tests,
format/ZLint/shellcheck and six native ELF audits locally. The networking branch
passed 281/281 Debug and ReleaseSafe tests and 168 Python tests, plus its static
checks and six native ELF audits.

`tools/probes/network-service.zig` now forces RV32 code generation of the
normal-boot owner `begin`, `poll` and `snapshot`. The architecture gate compiles
both `network_test=false` and `true`, without SDK headers, real credentials or
a device. This complements the existing AT/Hosted standalone probes: disabled
normal images alone cannot check the optional owner. A private negative-control
copy with the previously observed narrow backoff-integer defect was rejected
by this new gate; the repository source was not mutated for that control.

## Physical evidence and scope

The [positive device checkpoint](2026-10-27-network-lease-device.md) retains the
real early-renewal ACK, controlled C6-reset recovery and restored normal-image
result. Comparing its 250 source-snapshot paths against this landing leaves
one changed existing file: the CI architecture check. The runtime and image
build inputs are unchanged; the added compile probe is not an application
input. This is preservation of the recorded candidate's evidence, not a claim
that a newly rebuilt or merged binary has been physically booted.

Networking stays opt-in, with microSD coexistence rejected and diagnostic
injections disabled by default. Cold power cycles, uninterrupted AP loss and
return, natural T1/T2/rebinding/expiry, long-duration traffic and global IPv6
remain explicit qualification gates. TCP/DNS/TLS, BLE, application socket
handles, C6 TCP/IP offload and shared SDMMC arbitration remain implementation
work. Those limitations are retained when merging this experimental baseline.

Private Wi-Fi literals were checked against tracked landing content and were
absent. Private generated configuration, firmware and hardware logs remain
under ignored build directories; no build artifact is tracked.
