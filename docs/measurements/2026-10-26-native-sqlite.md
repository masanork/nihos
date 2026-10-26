# Opt-in native SQLite placement and execution

Date: 2026-10-26. Base: `0f0b9fc`; the accompanying
[JSON record](2026-10-26-native-sqlite.json) binds changed source, exact images,
loader/config, manifests, logs and validators. All execution results below
are local host or ESP-EMU results. No candidate firmware was flashed and no
new remote CI run was started.

## Result

SQLite now runs from mapped Flash in an opt-in independent native image.
Two CPU0 bootstrap sessions check 26 fixed queries after the ordinary native
SMP/interrupt/heap fixtures. Shutdown recovers the full owner heap after each
session. This is not yet a scheduled SQL service or bounded RPC implementation.

| Physical-profile build | App bytes | Primary static SRAM | Internal heap |
| --- | ---: | ---: | ---: |
| Integer | 79,216 | 75,904 | 87,936 |
| Floating | 82,368 | 80,064 | 83,776 |
| Compiled ILP32F | 82,688 | 80,320 | 83,520 |
| SQLite ILP32 | 727,856 | 95,744 | 68,096 |

All modes retain the separate 57,344-byte stack bank. The SQL image leaves
18,944 bytes above the 48 KiB internal-heap gate and 320,720 bytes in the
1,048,576-byte factory partition at Flash offset `0x10000`. The merged
Flash image, which includes the loader and partition table, is 793,392 bytes.

## Flash boundary and retained failure

SQL text is `0x40020000..0x4009d1c0` (512,448 bytes), followed by constants at
`0x4009d1c0..0x400aa5c0` (54,272 bytes). The C object allowlist contains the
SQLite engine, session and no-I/O VFS; the final SQL span has 1,427 named
functions. Kernel, interrupts, allocators, string helpers, compiler runtime,
all mutable data and all stacks remain in internal SRAM. The executed
`nih_sqlite_session_open` PC lies within its actual audited function.

The first attempt emitted more than two mapped segments. ESP-EMU's stock
IDF loader stopped at `assert(rom_index < 2)` before entering the kernel.
The exact failed ELF, app/merged images, manifest, audit and log are retained
under `build/qualification-native-sqlite-third-segment-failure/psram-4M/`.
The SDK was not modified. Filling the diagnostic-table gap with 62,660 zero
bytes lets esptool merge tables, SQL text and SQL constants into the second
mapped segment. The final auditor requires the two mappings, exact loaded
bytes and 64 KiB image congruence. No cache-off or Flash-write protocol follows.

## Allocation and stack observations

The old host-derived profile failed first on a 64-byte allocation during a
UTC query, then on a 32-byte allocation during CREATE. Both exact failed
images/logs are retained in `build/qualification-native-sqlite-quota64-failure/`
and `build/qualification-native-sqlite-quota32-failure/`. Increasing those
quotas to 64 produces `24,12,64,64,64,4,8,12,8,1`. The requested parent grows
from 50,640 to 57,104 bytes but remains one 65,536-byte buddy allocation.
There is no larger-class or system-allocator fallback.

| Class bytes | 8 | 16 | 32 | 64 | 128 | 256 | 512 | 1024 | 2048 | 4096 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Native peak cells | 20 | 10 | 22 | 23 | 16 | 3 | 6 | 8 | 3 | 0 |
| Profile quota | 24 | 12 | 64 | 64 | 64 | 4 | 8 | 12 | 8 | 1 |

| SQL emulator case | Sessions / queries | Heap before / after | Stack changed-word observation |
| --- | ---: | ---: | ---: |
| No PSRAM | skipped / 0 | 0 / 0 | skipped |
| 4 MiB | 2 / 26 | 1,801,536 / 1,801,536 | 6,472 bytes |
| 32 MiB | 2 / 26 | 16,022,848 / 16,022,848 | 6,472 bytes |

The CPU0 bootstrap stack reservation is 8,192 bytes with a 16-byte lower guard.
The fixed SQL fixture leaves 1,704 bytes above that guard, or 1,544 after
reserving a 160-byte trap frame. The leaf paint helper fills unused memory to
the caller's SP; volatile scanning reports the deepest changed pattern word.
Pattern scanning can miss untouched stack storage or matching values and does
not establish arbitrary SQL or interrupted-SQL bounds. The SQL phase runs
with MIE enabled but scheduler timers disarmed and the peer quiescent.

The C compiler records 1,435 static frame entries. The largest single frame is
768 bytes (`sqlite3_log`); the parser frame is 704 bytes. These are per-function
records, not recursive, whole-callgraph or Zig stack bounds. REAL uses software
arithmetic with zero hardware FP instructions in this mode. UTC dates remain;
the omitted `localtime` modifier produces NULL.

## Local verification and physical gate

Debug and ReleaseSafe each pass 148 host tests; 93 Python checks validate
complete logs, image placement, mutated evidence and explicit device/emulator
labeling. The original 308-point and session 321-point OOM suites, configured
profile retry/recovery and normal host SQL pass. Formatting, ZLint, ShellCheck
and six ordinary architecture links pass. All eight complete profile/mode
images were re-audited with the final validator. All twelve exact-artifact
emulator cases pass: integer 0/4/8/16/32/64 MiB, floating 0, compiled 0/32 MiB,
and SQLite 0/4/32 MiB. Device-profile builds are build evidence only.

The attached port `/dev/cu.usbmodem101` returned
`ESP-ROM:esp32p4-eco2-20240710` during a read-only capture. The execution
environment granted read access but did not grant serial write access. Chip
identification through esptool could not open the port before that grant;
no flash command was issued. This ROM line alone does not identify the full
board revision, Flash capacity or current application. The exact candidate
is pinned under `build/qualification-native-sqlite-device/candidate/`.

Before publication, identify the board/capacity and verify the write, then
capture at least three complete reset boots and check PSRAM/cache/SMP, both
owners' scheduler/heap recovery, all 26 SQL queries, SQL heap recovery and
stack observations against the device audit. Observe after the pass marker
for unexpected resets/traps. A USB reset is not a power cycle; cold-start
checks require an actual disconnect/reconnect. The current fixture performs
only two SQL sessions per boot and then idles, so idle time is not an SQL
endurance test. Screen/touch, persistent storage and production VFS are also
outside this fixture. No physical pass is claimed.

After physical qualification and publication, run ordinary CI and explicitly
dispatch Native CI on the published revision. Local checks cannot replace
either gate. See [ADR 0042](../adr/0042-native-sqlite-flash-execution.md).
