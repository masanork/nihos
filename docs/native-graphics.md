# Native graphics qualification

Status: local ESP32-P4 emulator execution and both revision-profile image
audits passed, 2026-10-28. Physical Tab5 qualification remains pending.

The opt-in `graphics` image executes real kernel boot, PSRAM preparation,
SMP/lifecycle/IPI fixtures, native task dispatch and timer handling before
running FreeType/HarfBuzz on a dedicated CPU0 task. Timer events come from
the emulated P4 peripheral rather than a host instruction hook. This remains
emulator evidence, not physical timing or visible display evidence. The
fixture hashes glyph IDs, advances and raster pixels; it does not present a
framebuffer or implement paragraph/ruby layout.

## Run

```sh
NIHOS_GRAPHICS_RV32_CXX=/path/to/riscv32-esp-elf-g++ \
  sh tools/run-native-graphics-smoke.sh
```

The existing pinned ESP-IDF loader toolchain is required. Device-profile
structural qualification, without accessing hardware, is:

```sh
NIHOS_GRAPHICS_RV32_CXX=/path/to/riscv32-esp-elf-g++ \
  sh tools/build-native.sh device graphics
```

Neither command opens a serial port or flashes hardware. Normal integer,
floating, compiled and SQLite configurations retain their partition/layout
contracts. This separate fixture uses its own loader directory and a **12 MiB
factory partition** because it temporarily embeds full pinned BIZ UD Gothic
and Mincho inputs. Production fonts are still intended for filesystem loading.
The unmodified fonts' OFL notices, FreeType FTL and HarfBuzz COPYING remain
with the pinned sources and must accompany a separately distributed bundle.

## Placement and C runtime

Only the generated, digest-bound `graphics_payload.o` function manifest can
execute in the graphics Flash span starting at `0x40020000`. Read-only tables
and font inputs follow. Kernel, task/interrupt and allocator code stay in
primary SRAM. All defined library/libc/compiler-helper globals except the
three fixture entry/result/PC symbols are renamed into a private namespace.
This prevents a library helper from silently redirecting a kernel call into
Flash. FreeType's default file/memory entry points remain unsupported;
callbacks and explicit ownership are mandatory. Dynamic initializers and TLS
are rejected by the image auditor.

The first image left an alignment gap between library constants and fonts.
It produced three mapped segments and the stock loader rejected it with
`rom_index < 2`. Explicit zero padding now makes records, library code/RO and
fonts one contiguous second mapping; descriptor/boot code is the first.
Audits compare every mapped byte with the ELF and verify both TTF SHA-256
values. The failed image and log are retained separately.

Source preparation also has a cross-process lock and a content witness. Once
prepared, subsequent builds verify and reuse the source tree without restoring
archives or reapplying patches under a compiler. Changed dependencies or a
modified cache fail explicitly; prepare a fresh generated source cache between
builds. Two concurrent preparers must return only the same source path, keep
all file modification times unchanged and retain the local OOM patch.

| Internal SRAM region | Reserved bytes | Purpose |
| --- | ---: | --- |
| Existing primary region | 163,840 | Kernel/static data and ordinary heap |
| Existing stack bank | 57,344 | Bootstrap, IRQ and original worker stacks |
| `0x4ff6e000..0x4ff76000` | 32,768 | One font task stack |
| `0x4ff78000..0x4ff80000` | 32,768 | Private library writable data/controller |

Both extra regions are checked against the actual loader's allocations and
the pinned SDK's revision-specific SRAM/cache windows. The loader copies
graphics initialized data; native CRT explicitly clears its BSS. Bootstrap
paints and guards the font stack before admission. The existing 56 KiB stack
bank is unchanged. All 64 KiB of extra reservations are counted as fixed SRAM,
including unused library-region capacity. Two clients share those regions.

| Measure | Emulator profile | Device profile, build only |
| --- | ---: | ---: |
| Primary static span | 96,000 B | 96,256 B |
| Remaining primary SRAM heap | 67,840 B | 67,584 B |
| Static reservations including stack/data regions | 218,880 B | 219,136 B |
| Application image | 11,559,824 B | 11,561,280 B |

Graphics code/RO occupy 560,448 B in Flash. TTF inputs occupy 10,821,312 B,
plus 16 B alignment in their section; they account for most of the image.
Private initialized data/BSS occupy 19,924 B within the 32 KiB region. These
figures exclude document models, display buffers, native font-filesystem
caches and application routing. The two fixed transport queues reserve
1,152 B in primary SRAM. Transport code/control together add 4,096 B to the
primary static span versus the prior client-cycle fixture; no further stack
or library SRAM region is reserved.

## Ownership and execution

The font task uses a real scheduler generation/slot identity. Its backing
adapter obtains bounded, noncontiguous extents from the **already initialized**
native CPU0 PSRAM heap; it cannot initialize or replace that heap. Canonical
child handles stay in the task ledger. Root/extent changes are bounded and
locally IRQ-masked; library work and source copies execute with MIE enabled.
Other native profiles retain zero extent-group slots.

The fixture runs two open sessions, four body sizes with half-size ruby runs
and horizontal/vertical shaping: 16 cases with forced auto-hint per cycle.
It runs four open/draw/close cycles for both clients on the same live task,
for 64 cases in total. Only the final close returns through the actual task ABI.
Native EXIT closes the ledger; bootstrap drains one extent per cleanup step,
reaps only after cleanup and checks complete heap recovery.

The initial [single-cycle receipt](measurements/2026-10-28-native-graphics.json)
records the first native integration. The
[client-cycle receipt](measurements/2026-10-28-native-graphics-client-cycles.json)
records the earlier active-idle experiment. The current
[request/wait receipt](measurements/2026-10-28-native-font-request-wait.json)
records queued requests on one live task:

- All 64 cases repeat the same 16-hash matrix, which also matches the
  sanitized host reference. An `auipc` sample inside the C++ entry confirms
  execution in the whitelisted library function.
- The timer captures the font task 6,371 times, including 6,359 during
  shaping/rasterization stages; bootstrap advances 11,299 times.
  Five request waits span ten real scheduler ticks in total, with zero
  additional font-task runtime while blocked.
- Stack watermark/frame observation reaches 16,980 B, leaving 15,772 B above
  that observation and the 16 B guard in a 32 KiB reservation. This is not a
  worst-case or native IO call-chain bound.
- Two clients peak at 1,310,976 B of actual buddy backing. Closing clients
  leaves 65,792 B of HarfBuzz backing; task-ledger retirement then restores
  CPU0's original 16,022,848 B of free heap.
- Other-task/dispatch operations are rejected; the owning task also rejects
  an invalid address without changing free heap. The 1,024-record controller
  peaks at 694 records.

## Client and service lifetimes

Closing the last client frees its face and source-cache extents, while
service-owned HarfBuzz state remains in one backing extent. Every cycle must
leave exactly the same retained charge and matching native free-heap balance.
The next cycle reuses that live service state without another backing init,
task admission or stack paint. All 16 output hashes must match the first
cycle; the final matrix must also match the independent host reference.

With zero clients, the font task receives the next request through a bounded
channel. Empty receives block in the scheduler; there is no active idle loop
inside the font worker. Bootstrap deliberately holds each request for two
real ticks and verifies unchanged worker runtime. This is font-task blocking,
not whole-system WFI or a physical power/timing measurement.

The [request-boundary decision](adr/0044-native-font-request-waits.md) specifies
two two-slot SPSC queues, copied IDs/results and one client dispatcher. Four
render requests produce 64 cases, followed by an ordered stop request. The
terminal reply must be copied and its space notification completed before an
independent acknowledgment permits worker EXIT. A task yield is forced between
releasing that reply slot and notifying the worker to exercise this lifetime
window. All five replies, acknowledgments and empty queues are required.

This finite matrix endpoint does not accept application text or expose shared
face pointers. Multiple applications need a broker or distinct client channels;
concurrent producers, cancellation and service restart remain unqualified.

Retirement ends this library lifetime. HarfBuzz globals would refer to retired
backing afterwards, so the fixture refuses another admission and never calls
the libraries again. It is **not** an application-ready font service, restartable
library lifetime or general client cancellation. Production integration must
retain service-owned state across client closes and define safe shutdown/restart
separately.

## Remaining integration

Flash input is a qualification mechanism, not production storage. Native SD
currently has a boot-only controller/clock lifetime. A font read-at provider
needs persistent ownership, task-safe clock/waits, large-file handles, source
revision/removal handling and failure without publishing partial output.
The boot-only littlefs fixture's 64 KiB file/read-count limits cannot be reused
for these multi-megabyte TTFs.

Physical cache/PSRAM/SMP/stack behavior, display output, SD input, removal,
storage-induced latency and repeated service startup remain unqualified.
No hardware was accessed or firmware published in this stage.
