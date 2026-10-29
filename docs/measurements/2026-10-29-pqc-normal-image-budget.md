# ML-DSA fixture against the normal Tab5 image: build boundary

Base `b5a0c2e`, Zig 0.17.0 and ESP-IDF 5.4.4 loader, device profile for
ESP32-P4 rev1/2. No Tab5 was contacted or flashed. The build uses the normal
integer configuration: display scanout, live console, 200 MHz PSRAM setup,
C6 networking and on-demand devices. No Wi-Fi credentials were supplied.
The experiment uses the earlier fixed-vector ML-DSA-65 arena fixture; it is
not the proposed asynchronous verification service.

The PQC-disabled candidate completed the native image audit. Its primary SRAM
heap **span** is 62,848 B; the linker requires at least 49,152 B. Thus the
static headroom above that floor is **13,696 B** for this exact baseline, not
runtime application free memory. The baseline has 100,992 B primary static SRAM
and a 185,648 B application image. Audit, build options, hashes and source
witness are retained in [the evidence](evidence/2026-10-29-pqc-normal-budget/).

With the same build settings and `NIHOS_NATIVE_PQC_VERIFY_PROBE=2`, the normal
candidate failed to link:

```text
error: ld.lld: native SRAM heap below 48 KiB
```

The 48 KiB check was not changed. Because linking failed, there is no audited
PQC-enabled normal firmware, measured on-image SRAM difference, runtime
coexistence result or input-to-display latency result. A previous minimal
emulator profile showed +20,224 B static SRAM, but that is not an exact
normal-profile delta and does not replace this failed build. The build process
can leave an older ELF in its output directory after link failure; the only
valid baseline artifacts here are the separately retained `build/pqc-normal-off`
copies and their audit hashes. Do not use the failed output's stale ELF.

## Placement investigation, not an integrated image

The disabled candidate's allocated `.flash.boot`, `.flash.devices` and
`.flash.time` sections end at `0x40008fe2`, leaving 28,702 B before the end of
the 64 KiB boot Flash window. Its `.flash.rodata` ends at `0x4001d8f4`,
leaving 9,996 B in that records window. These are address gaps in this exact
baseline, not guaranteed usable bytes: placement alignment, segment layout,
other contents, XIP mapping and audit restrictions still apply.

Separately linking the failed attempt's compiled PQC C objects as a single
fixture root, with a tiny stand-in C runtime and no-op observer, produced
11,898 B executable and 7,584 B read-only allocated sections. The fixture's
public key and signature are included. This freestanding object-link exercise
is not the real firmware, excludes Zig service overhead, uses a stub, and has
no execution or image audit. `sh probes/pqc/normal_link_study.sh` reproduces
the diagnostic from the failed build's retained C objects. It cannot establish that the normal image will
link or that those address gaps can safely be used. It does make a targeted
XIP-placement experiment worth attempting without reducing the SRAM floor.

A separate link-only test in the retained `/private/tmp/nihos-pqc-xip-study`
worktree moved the two fixture C objects to new `.flash.pqc` and
`.flash.pqc.rodata` sections. It linked with a **60,992 B** primary heap span
(1,856 B below the disabled baseline); the sections contain 11,800 B of code
and 6,620 B of read-only data. The application image was generated, but the
unchanged image audit correctly **rejected** the unapproved `.flash.pqc` section.
The [patch, section list, audit failure and hashes](evidence/2026-10-29-pqc-normal-budget/)
are retained. This unqualified image was not executed or flashed. The result
establishes a link-layout possibility, not safe XIP execution, an audited image,
or the final service's SRAM cost.

Moving C code and fixture data into Flash must preserve the existing bounded
section/function audit, prove the full reachable call graph cannot execute when
the cache is unavailable, account for two mapped segments, and separately
measure resulting SRAM and Flash sections. Do not auto-allow functions found
in the resulting ELF. The observed fixture also runs synchronously during
bootstrap, before normal-ready; merely making it link would not prove UI
responsiveness. The intended asynchronous ownership/cancellation/trust
boundaries and tests are in [ADR 0054](../adr/0054-pqc-verify-service-contract.md).

Reproduce in an isolated checkout with the pinned toolchain and mldsa-native
source checkout:

```sh
sh tools/build-native.sh device integer
NIHOS_NATIVE_PQC_VERIFY_PROBE=2 NIHOS_MLDSA_SOURCE=/path/to/mldsa-native \
  sh tools/build-native.sh device integer
```

The second command is expected to fail for this source and exact options.
Builds only; neither command writes to a device. Real latency, actual PSRAM
and SRAM usage with live UI, cache-off behavior and physical device results
remain unmeasured.
