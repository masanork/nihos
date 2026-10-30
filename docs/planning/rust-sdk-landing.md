# Experimental Rust SDK landing

The first landing is an opt-in application experiment: the same Rust sample
must draw through native FFI and Wasm, receive serial `0 -> 1 -> 0`, and release
its OS-owned resources on `q` or failure. The kernel and native drivers stay
Zig-first. The SDK and its graphics/task ABIs remain provisional.

## Consolidation boundary

The source experiment is retained unchanged in `/private/tmp/nihos-rust-app-sdk`
on base `c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. Its historical measurement
reports and evidence describe those candidates, including the limited native
display-owner physical check; they do not qualify a later integrated image.

The isolated integration branch is `codex/rust-sdk-integration-20261030`, based
on main `3d21dcb1b798c745c084cb9d1d74fddbd231747f`. It retains main's camera
overlay, storage, PMP, graphics and xy changes. Review units, in dependency
order, are:

1. `no_std` SDK, shared Rust application, native graphics adapter and host/RV32
   fixtures.
2. Canonical package/trust formats, signature admission, two-slot recovery and
   host process/file tests. These are OS infrastructure, outside the SDK API.
3. WAMR host/RV32 port, C compatibility helpers, native boot/task fixtures and
   emulator UART/cleanup checks. All runtime options default off.
4. Historical design/measurement reports and exact candidate evidence.
5. Reproducible host CI, opt-in emulator CI, and this finite landing checklist.

An additional prerequisite commit initializes the new main xy/font buffers and
removes a redundant cast to satisfy the existing lint gate. It is separate from
the SDK/runtime changes and does not edit the original main worktree.

WAMR is fetched separately at revision
`25bd7eb63e828e4bd242cc9b38d260b4b31c6605` (2.4.5). Its Apache-2.0 license with
LLVM exception remains in the checkout and is copied into the native Wasm build's
`licenses/WAMR.txt`. The retained alignment experiment patch is research only;
ordinary runtime builds require the unmodified upstream checkout.

## Verification entry points

Use Zig 0.17.0 and Rust 1.98.1 with `wasm32-unknown-unknown` and
`riscv32imac-unknown-none-elf`. The latter uses soft-float `ilp32`.

```sh
sh tools/bootstrap-zig.sh
rustup toolchain install 1.98.1 --profile minimal --target wasm32-unknown-unknown,riscv32imac-unknown-none-elf
RUSTUP_TOOLCHAIN=1.98.1 sh tools/run-rust-sdk-host.sh
.tools/zig-0.17.0/zig build test
.tools/zig-0.17.0/zig build test -Doptimize=ReleaseSafe
sh tools/run-static-analysis.sh
```

`zig build test-app` runs the focused admission/recovery suite, also included in
`zig build test`. The host runner adds Rust native/Wasm parity, bounds, WAMR
allocation-fault recovery, signed-journal execution and process termination.
The `Experimental Rust SDK` workflow runs these host checks on pull requests.
Its manually dispatched emulator job additionally builds the pinned ESP-IDF
5.4.4 bootloader and runs:

```sh
sh probes/rust-app/run-emulator.sh
sh probes/wamr-host/run.sh
sh probes/wamr-native/run-emulator.sh
```

The Wasm runner requires the bootloader from the first command, the matching
RISC-V GCC/binutils on PATH (or `NIHOS_RISCV_CC`), and an esptool Python
environment (`NIHOS_IDF_PYTHON`). It checks the digest of the module built in
that run; historical module hashes are not used as current evidence.

CI configuration and local passes are separate evidence. A remote CI run is
still required before merging. Neither is physical qualification.

## Remaining work, in order

Native foreground ownership is now wired behind `NIHOS_NATIVE_RUST_SESSION=1`:
`rust-app` opens the sample from the normal shell, with a separate PSRAM lease,
per-input drawing/publication, and quit/cancel/failure cleanup followed by a
console repaint. The same session and rotated display-copy code run with native
Rust and signed WAMR on the host. A headless normal-profile RV32 fixture exercises
the actual native backend while both hart timers run. See the
[session integration report](../measurements/2026-10-31-rust-session-normal-owner.md).
This does not complete the Wasm portion of the next gate.

1. **Wasm task ownership in the normal OS.** Connect WAMR to the common session
   through an OS-registered task, with its leased 64 KiB stack accepted by the
   task runtime and interrupt-stack validator. Do not switch SP behind the
   scheduler or disable interrupts around guest execution. Preserve bounded
   calls, admitted rights, quit/trap/cancellation cleanup and camera/console
   ownership. Then exercise `0 -> 1 -> 0 -> q` through both normal backends.
   The native headless fixture and Wasm host parity test do not establish RV32
   Wasm scheduling or physical scanout.
   A long ROM-console no-input poll while CPU1's qualification tasks were already
   running exposed a timer clock-refresh rejection during integration. The boot
   fixture now keeps CPU1 before task admission until WAMR has stopped and freed
   its lease; normal completion then runs both harts' scheduler/timer soak.
   The failure matrix checks cleanup with CPU1 quiescent. It does not qualify
   a blocking ROM polling loop alongside running application tasks.
2. **Runtime decision and candidate profile.** Resolve the WAMR alignment
   adoption question for the exact RV32 configuration before permitting a
   Wasm device image. The AArch64 UBSan finding and narrow experimental patch
   remain open; neither a host pass nor RV32 compilation proves engine safety.
   Build and audit one bounded native/Wasm device candidate with explicit
   memory, stack, execution budget and shutdown behavior.
3. **Exact-candidate physical check.** When Tab5 is available, verify candidate
   identity, boot, visible screen output, serial transitions and quit/error
   cleanup. Keep emulator, serial-publication and optical observations separate.
   Record resource use and a bounded repeated-launch run. Retain/verify the
   previous image when restoring it.
4. **Review and merge.** Reconcile the final main head, run required CI, review
   the ABI and evidence, and merge only after the agreed physical gate. Keep
   the experimental feature disabled in ordinary builds.

Production keys/protected counters, native Flash installation and power-loss
qualification, touch/keyboard SDK events, concurrent apps and a stable public
SDK are follow-ups. They do not expand this first landing's acceptance scope.
Native FFI remains trusted shared-address-space code.
