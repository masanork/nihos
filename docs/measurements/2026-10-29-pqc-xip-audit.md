# Restricted ML-DSA fixture Flash placement and audit

The opt-in `NIHOS_NATIVE_PQC_XIP=1` profile moves the pinned ML-DSA-65 arena
fixture's C code and read-only data into the existing mapped Flash windows.
It is restricted to the normal integer device arena fixture with network and
devices enabled, and excludes SDMMC and card modes. This is **not** an
asynchronous crypto service, an approved firmware-update verifier, or a
cache-off-safe runtime.

## Same-source device-profile builds

Both are ESP32-P4 rev1/2 device-profile builds with display, live console,
200 MHz PSRAM setup, network and on-demand devices enabled; Zig 0.17.0,
ESP-IDF 5.4.4 loader, no configured Wi-Fi credentials. The only relevant switch
is enabling the opt-in fixture/XIP profile. No device was contacted.

| Resource | Disabled | XIP fixture | Difference |
| --- | ---: | ---: | ---: |
| Primary static SRAM | 100,992 B | 102,848 B | +1,856 B |
| Primary SRAM heap span | 62,848 B | 60,992 B | -1,856 B |
| Application image | 185,648 B | 206,192 B | +20,544 B |
| PQC Flash executable section | 0 | 11,800 B | +11,800 B |
| PQC Flash read-only section | 0 | 6,620 B | +6,620 B |

The heap span is not runtime free capacity. XIP image cost includes fixture,
verification code, observation and layout/padding; it is not the cost of a
production service. Exact audit reports, options, ELF/image hashes and source
witness are in [the evidence directory](evidence/2026-10-29-pqc-xip-audit/).
The exact ELF and images remain under `build/pqc-xip-audited` and
`build/pqc-xip-disabled` in the study worktree.

## What the audit establishes

The audit requires the explicit ELF profile marker, the specific device mode,
the two RX/RO Flash sections at bounded, aligned locations and corresponding
linker boundary symbols. An independent fixed list of 11 function names is
required exactly once with bounded non-overlapping extents; it is not derived
from the linked ELF or a generated allowlist. The complete two mapped image
segments, including padding and PQC bytes, are compared against the ELF. The
existing 48 KiB heap gate, ROM ABI, loader, FP-instruction and section checks
remain in force. Both disabled and enabled images passed this structural audit.
The pinned upstream checkout/revision and clean tracked files are verified by
the build; the source witness records hashes of the local wrapper and build
inputs. This is not signed code authentication or a cryptographic audit.

Negative checks reject an extra/unapproved function, missing function,
overlapping extent, disabled profile, writable/executable read-only section,
and actual-ELF mutations of a PQC symbol and read-only permissions.

A separate disassembly report bound to the ELF hash found one annotated direct
incoming branch, from `pqc_arena_probe.run` to `nih_pqc_arena_fixture`. It also
found two unannotated indirect `jalr` instructions in the whole image. The
report is a useful inspection aid, not a complete call graph: indirect calls,
other branch encodings, runtime control flow and cache-off paths are not
proved. The audit itself does not prove the Flash fixture is unreachable from
interrupts, that Flash is always mapped, or that all cache-off dependencies are
coordinated.

## Cache and worker boundary

The current native tree has no Flash program/erase path and no cross-core
cache-off coordination. The opt-in fixture runs synchronously at boot, before
normal-ready. It does not establish input-to-display responsiveness or any
actual independent verification worker. A host-only cache-gate model tests
closing admission, waiting for holders and both generation-matched hart
acknowledgments, restoring the cache, stale epochs, failure quarantine, and a
check-then-enter race. It cannot enforce or validate native hardware behavior.
The service contract and outstanding worker/cache coordination are in
[ADR 0054](../adr/0054-pqc-verify-service-contract.md).

No XIP candidate was executed in ESP-EMU or on physical Tab5; no device was
flashed. Physical speed, UI latency, code/PSRAM cache behavior, DMA and Flash
write interaction, stable trust anchors and side-channel resistance remain
unqualified. A future product integration must implement and test the real
quiescence protocol before any cache-off operation can coexist with XIP.
