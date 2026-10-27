# Native P4 SDIO transport and standalone C6 boot fixture

- Date: 2026-10-27
- Branch: `feat/c6-network-offload`, extending `96aa7ff`
- Evidence: host tests, target compilation/linking and offline image auditing
- No serial port was opened and no physical device was flashed, reset or selected for OTA

## Implementation

Added a boot-exclusive ESP32-P4 slot-1 host for CMD0/5/3/7 enumeration,
CMD52 function setup and CMD53 reads/writes. The clock path selects slot 1's
divider, and the card/host switch to 4-bit operation after function 1 is ready.
The requested mode is 400 kHz, derived from the assumed 40 MHz host source;
no physical clock/timing measurement is claimed.

The C6 stream layer uses its 20-bit cumulative RX count and 12-bit TX buffer
credits, with the pinned peer's 512-byte buffer/10-credit profile. Logical
FIFO byte count is encoded in the address independently from padded DMA
count. TX padding is zeroed; RX padding never reaches caller storage. Zero
credits returns no progress. Detected discontinuity or ambiguous transfer
retires the stream rather than rebasing counters or replaying.

The CPU0-only fixture supplies aligned static descriptor/data buffers and
ROM cache maintenance, resets the C6, drains startup bytes, negotiates the
AT profile, then queries GMR and SYSRAM. It has fatal traps, no P4 RTOS/heap
use, no CPU1 release and no enabled P4 interrupt sources. It finishes with
a report and pass/fail marker, then halts. These are intended behaviors from
source, not observations of a physical run.

## Verification

| Check | Result | Boundary |
| --- | --- | --- |
| Zig Debug host suite | 140/140 passed | Includes 12 new SDIO/stream/link tests |
| Zig ReleaseSafe host suite | 140/140 passed | Host execution |
| Static analysis | Passed, zero ZLint warnings/errors | 63 source/probe files, shell checks |
| Image-policy Python suite | 5/5 passed | Includes required fixture function identity |
| Native SDIO/AT RV32 compile probe | Passed | No SDK or hardware execution required |
| Existing six native ELF links | Audits passed | Baseline device/emulator integer/FP profiles |
| Standalone P4 C6 image | Built and audited | SDK-dependent, integer-only SRAM/ROM image |
| Baseline kernel submitted to C6 audit | Rejected | Required C6 function symbols were absent |

SDIO models cover slot selection, CRC/response flags, invalid commands before
MMIO, function setup, R5 failure, DMA length/direction/ownership, transfer
timeout and failed cleanup. Stream models cover tail padding, one-byte RX
buffer boundaries, counter wraps, credit exhaustion, discontinuity and
ambiguous failures. A synthetic peer exercises all AT profile commands,
binary socket messages and GATT notifications with 1/3/17/512-byte chunks.
It checks stream envelope behavior, not actual TCP/IP or BLE radio stacks.

## Target artifact

Zig 0.17.0; P4 SDK v5.4.4 commit
`296b6eab9445fd720e71aecab961e2d3fbca9944`, with a clean SDK checkout.
The P4 peer requirement is the separately built ESP-AT C6 candidate from the
[previous milestone](2026-10-27-c6-at-controller-build.md), not factory Hosted
firmware. No attached chip revision or C6 version was read in this task.

| Artifact/fact | Value |
| --- | --- |
| P4 application image | 65,616 bytes |
| Image SHA-256 | `0f5f3235f129c81357b188bfc1b6df9a53a5a32dd28f54eedbf5ed0deaad2d6d` |
| ELF SHA-256 | `4cd4ec0918b2ff58496df13679d665a6adf7763482d752f3bda4cbacf3bdcac1` |
| SRAM code/data/stack reservation | 73,600 bytes in `0x4ff00000..0x4ff20000` |
| Stack reservation within that total | 32,768 bytes; inherited four 8 KiB areas, CPU1 areas unused |
| Unused tail reservation | 57,472 bytes; no allocator runs in the fixture |

These sizes are link-layout facts, not stack high-water or runtime network
memory measurements. The image uses the existing two read-only flash metadata
segments; all native executable code and ordinary data are in SRAM. The audit
checks resolved symbols, known ROM ABI, integer-only instructions, image/ELF
digest binding and required C6 fixture functions. It is not a proof of memory
safety, DMA/cache correctness or successful execution.

Artifacts are under `build/c6-sdio-probe/`: ELF, application bin, audit,
source/artifact SHA-256 receipt, loader/config and build logs. The receipt
records the build worktree as `96aa7ff` plus uncommitted changes; exact compiled
input hashes are retained so the later commit can be matched. The build tool
does not generate a command that selects or flashes a real device.

## Failed integration attempt and correction

Initially the C6 path was linked into the full existing native bootstrap.
That exceeded the fixed SRAM region by 12,160 bytes at stack allocation,
before meeting the minimum 16 KiB heap reservation. That link was rejected.
The normal native startup/build scripts were restored to their prior form,
and the separate CPU0 fixture above was built in the same 128 KiB map.
This does not solve the eventual combined native service memory budget.

The first LL shim compile also exposed missing SDK include prerequisites;
the required `stddef.h` and GPIO constant header were added. An SDK export
script cleared a generic local `idf_path` variable; the dedicated build tool
now uses a task-specific name. These setup failures preceded the successful
image and were not physical device attempts.

## Remaining gates

C6 download/recovery access and flash backup, actual P4/C6 image identities,
board timing and pad sequencing, physical enumeration, bidirectional DMA and
cache behavior, the AT fixture's complete serial report, AP/TCP/GATT traffic,
heap/latency/loss, IRQ integration, microSD/controller arbitration, permanent
service memory/lifetime and application resource generations remain open.

See [ADR 0044](../adr/0044-c6-sdio-boot-transport.md) and the
[fixture procedure](../../probes/c6-sdio/README.md). Do not infer physical Wi-Fi
or BLE operation from the model pass or the audited image.
