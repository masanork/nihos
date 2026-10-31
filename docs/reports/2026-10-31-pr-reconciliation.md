# Open PR reconciliation, 2026-10-31

The audit started from `origin/main` at `3efd1f80d78db8f95bef4c8dc8280b66fe0ac584`.
There were eight open draft PRs. None of their complete heads was an ancestor
of main: a superseded feature is distinct from an already merged commit.
Branches and existing worktrees are retained so superseded experiments remain
available without resetting concurrent work.

| PR | Decision | Reason and retained work |
| --- | --- | --- |
| [#71](https://github.com/masanork/nihos/pull/71) | Supersede the old UI; migrate useful changes | Main's xy workspace already replaces the unsaved single ASCII row, including cursor editing and HID decoding. Retain normal-build keyboard enablement from `26883bf`; migrate the file-backed checkpoint/reopen test to the actual xy UTF-8 document. Do not reintroduce the old launcher editor. |
| [#75](https://github.com/masanork/nihos/pull/75) | Integrate | Opt-in CMD24 probe, staging/cache ownership checks and the cross-slot lease fix are absent from main. Keep the normal storage bus read-only. |
| [#77](https://github.com/masanork/nihos/pull/77) | Integrate with #75 | Shared read/write admission, retained DMA leases, stop-ticket cleanup and recovery gating after uncertain writes belong together. |
| [#78](https://github.com/masanork/nihos/pull/78) | Adapt and integrate | Move the test from the obsolete launcher document to xy. Retain modeled torn-write recovery, sector-range isolation and stop-ticket checks. Include Japanese UTF-8, newlines and spaces. |
| [#79](https://github.com/masanork/nihos/pull/79) | Superseded by xy startup in #85 | Do not replace current xy startup with the older ASCII shell. The terminal's command history and asynchronous prompt protection are not claimed as present in xy or the diagnostic fallback; their implementation remains on `codex/terminal-shell` for any later explicit terminal work. |
| [#87](https://github.com/masanork/nihos/pull/87) | Land separately after final-head CI | Native TrueType rendering, Scheme view settings and physically diagnosed stack/preemption fixes remain useful. Its exact-candidate physical evidence is in the linked measurement reports; new integration builds are not new device trials. |
| [#88](https://github.com/masanork/nihos/pull/88) | Keep draft | Its description explicitly requires recovery after a failed physical restoration before landing. Preserve the JPEG result and recovery gate. |
| [#89](https://github.com/masanork/nihos/pull/89) | Keep draft | Its description records panel flicker and requires a publication/redraw fix plus retest. This reconciliation does not absorb parallel local edits. |

## Scope of validation

The SD/controller integration uses hosted MMIO, a fault-injecting media model,
and a modeled durability barrier. The file-backed test closes and reopens an
ordinary host file. Neither path registers writable native storage, chooses or
formats a physical region, nor establishes SD-card power-loss durability.

The normal build still starts xy, keeps the native FS read-only, and can disable
the I2C keyboard explicitly. The workflow checks the keyboard option in the
current `native-device-network-devices-camera` output directory. Its earlier
PR path predated the default camera integration. Enabling it first exposed the
48 KiB SRAM heap floor. Place only the existing foreground keyboard setup
entry in the already mapped device Flash span, like the existing input poll,
and extend the image auditor with that exact entry-name pattern. Interrupt
handlers and cache-off code retain their existing placement.

Final integrated host tests, hosted normal-FS probes (including negative
controls), static/native audits, normal device image checks and GitHub workflows
are recorded in the integration PR. Physical keyboard, writable native storage,
cold-power behavior and the exact integrated image remain separate device gates.
