# xy Scheme strings: provisional experiment

This worktree experiment adds bounded `string-length`, `string-append`, and `string=?`. Length counts Unicode scalar values; invalid UTF-8 is rejected. Individual strings retain the existing 128-byte limit. This is not complete R7RS string support.

On parent commit `9710e8681f0a4cee7236f38eda62f5187669ab49`, the host focused test passes and the 20-case feature probe reports 11 matches and 9 errors. These finite examples are not a conformance rate. Device-profile image audits passed with 49,216 bytes (no sqld) and 52,416 bytes (sqld), versus the 49,152-byte floor. The no-sqld margin of 64 bytes is too small to treat as a completed integration: investigate placement and rerun both audits on the current base. No RV32 emulator or physical device result for this experiment is claimed.

The initial implementation using separate Unicode count and validation paths failed the heap-floor link assertion. A shared Flash-placed scalar-count helper passed the existing floor and image audit, but retains very little margin. The parent branch has since been rebased; these numbers do not establish the rebased image footprint.

After rebasing onto main `47875078be854362d7695146f2808b0cdfcfb50d`, both device profiles were rebuilt and audited: no-sqld remains 49,216 bytes, and sqld 52,416 bytes. Under the same options the rebased quasiquote parent `89450927df82b91b3366be66b65aaa0bb1ab5579`, without these string changes, also yields 49,216 bytes no-sqld. Thus this result does not show the string changes caused the 64-byte margin. It remains important to restore headroom and assess other configurations before integration.

An integration preview at `949f3386` includes the separate SRAM-placement fix, recursive bindings, quasiquote and this string implementation. Its no-sqld trace device audit passes with 49,728 B heap, 576 B above the floor. This is a preview, not evidence for an eventual merged SHA. [Audit](evidence/2026-11-03-xy-strings-wip/combined-trace-no-sqld-audit.json).

A finite eight-case [differential probe](evidence/2026-11-03-xy-strings-wip/string-differential.json) using `tools/xy_string_probe.py` matches pinned Chibi, including Japanese, emoji and combining characters. This does not demonstrate complete R7RS string conformance.

The same integration preview's sqld trace device image also passes its audit with 52,928 B heap. [sqld audit](evidence/2026-11-03-xy-strings-wip/combined-trace-sqld-audit.json). A separate CPU-initialization-disabled no-sqld RV32 emulator ELF accepts Japanese and emoji input, evaluates length, append and equality, and recovers to a later arithmetic expression. [Emulator trace](evidence/2026-11-03-xy-strings-wip/combined-no-sqld-emu.log), [ELF SHA-256](evidence/2026-11-03-xy-strings-wip/combined-no-sqld-emu-sha256.txt). This does not establish physical-device behavior or replace tests of the eventual merged candidate.

The equivalent sqld RV32 emulator ELF passed the same string input and recovery observations. [Emulator trace](evidence/2026-11-03-xy-strings-wip/combined-sqld-emu.log), [ELF SHA-256](evidence/2026-11-03-xy-strings-wip/combined-sqld-emu-sha256.txt). In the integration preview, the existing 20-example [R7RS probe](evidence/2026-11-03-xy-strings-wip/combined-r7rs-probes.json) gives 11 matches and 9 errors; it is not a conformance percentage.
