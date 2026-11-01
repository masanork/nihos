# WAMR graphics rights bound to native instance owners

The subsequent [native surface run](2026-10-30-wamr-native-surface.md) connects
the authorized imports to the RGB565 renderer and records the next candidate.

Date: 2026-10-30. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. Executed in the ESP32-P4
native emulator with RV32IMAC/ILP32. Physical Tab5 qualification remains pending.

The native runner now attaches a private owner context to each WAMR instance.
The context receives the graphics service bit returned by the authenticated
package boot path, identifies its module instance and has an active flag. Both
graphics imports require the active, matching context and its graphics bit.
Missing rights, inactive owner, mismatched instance and detached owner return
the fixture permission error -5 before drawing or guest-text mapping.

The guest application is called in each denied state before its normal frame
tests. Every denial returns -5 through the Rust SDK and leaves accepted host
calls at zero. A direct text-import check uses an invalid guest offset while
graphics rights are removed; it must return -5 with no WAMR memory exception.
Restoring the context permits the normal drawing/error/trap/budget tests.

Each of the two instance lifecycles has its own context. The common teardown
path deactivates and detaches that context before deinstantiation, including
cleanup paths. Native boot and the host runner require the owner record:

```text
NIHOS_NATIVE_WAMR_OWNER checks=0000000f released=00000001 services=00000001
```

The checks mask contains one bit per successful negative case: missing graphics
rights, inactive owner, mismatched instance and detached owner. The release bit
requires both context active flags to be false after the final cleanup. Normal
execution still reports nine accepted drawing calls across two independent
load/instantiate/exec-env/destroy cycles. Both buddy arenas return to the exact
baseline free counts, and the PSRAM lease is released. Requested runtime and
linear peaks remain 19,737 and 65,536 bytes; the private-stack high-water is
23,660 bytes inside the existing 64 KiB stack.

Boot first recovers sequence 1 from private mutable journal fixtures, interrupts
the sequence-2 commit write, verifies a fresh coordinator recovers sequence 1,
then retries and recovers sequence 2 for execution. This remains the previously
tested same-process restart model. Its root/trust/install/recovery closure
reports 106,780,693 emulator cycles. After WAMR teardown, all three 100-round SMP
markers, the 300-round soak marker and integer completion marker are present.

The structural audit reports a journal-only load source, no independent raw-Wasm
symbol, no undefined symbols, 249,680 Flash text bytes and 35,147 read-only bytes.
The Wasm, sequence-1 package and sequence-2 update package retain their previous
hashes. The new canonical ELF SHA-256 is
`7c73e620635acf6b7fff7c7f9392fe500bced81515e0e4dff7d8f82ce5ca8841`;
the merged flash image SHA-256 is
`7271223b0a9b3417f19b42c3e7843188f7e149b84977d28bef7d84445e10df27`.

Run with the existing emulator runner:

```sh
NIHOS_ZIG=/path/to/zig-0.17.0/zig \
NIHOS_RISCV_CC=/path/to/riscv32-esp-elf-gcc \
NIHOS_IDF_PYTHON=/path/to/esptool-python \
sh probes/wamr-native/run-emulator.sh
```

The run also passes its host admission, cryptographic, file/process, kill-matrix
and corruption-control regressions before building the image. Retained
[emulator log](evidence/2026-10-30-wamr-native-owner/emulator.log),
[build log](evidence/2026-10-30-wamr-native-owner/build.log),
[structural audit](evidence/2026-10-30-wamr-native-owner/image-audit-wamr.json),
[candidate hashes](evidence/2026-10-30-wamr-native-owner/candidate-sha256.txt), and
[media hashes](evidence/2026-10-30-wamr-native-owner/boot-media-sha256.txt)
bind this emulator candidate.
The [changed-source hashes](evidence/2026-10-30-wamr-native-owner/source-sha256.txt)
identify the native owner, boot/media adapter, report, linker and build scripts
used for this candidate.

This establishes synchronous import rights and context lifetime for the single
CPU0 WAMR owner. Imports still use the bounded drawing probe rather than a live
display service. Concurrent owners, cross-hart calls, in-flight revocation,
blocking-service cancellation and physical scanout remain outside this fixture.
The native boot fixture retains its fixed graphics grant; the broader-platform-
grant and zero-grant admission cases remain separately host-tested. Private RAM
journals, public test roots and the fixture counter provide no native persistent
Flash or protected-counter qualification.
