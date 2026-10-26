# 0042: Opt-in native SQLite Flash execution

Status: accepted for local host/emulator qualification, 2026-10-26. Physical
Tab5 qualification is required before publication and remains pending.

## Placement and loader contract

Add a fourth `sqlite` mode without changing the ordinary integer, floating or
compiled modes. Use RV32 IMAC/ILP32, retain SQLite REAL with software arithmetic,
ZERO_MALLOC and UTC-only policy, and link the existing prefixed allocator and
session API. The official amalgamation is restored from a checksum-verified
archive shared by host and native builds; SDK sources remain unchanged.

Only functions from the exact SQLite, session and no-I/O VFS object manifests
may execute from the new `0x40020000` Flash span. All their read-only constants
are adjacent. Kernel/task/interrupt/allocator code, compatibility strings,
compiler runtime, mutable data and stacks stay in SRAM. The existing two
CPU0 PSRAM boot functions keep their distinct whitelist. No cache-off or Flash
write protocol is introduced.

The pinned stock P4 loader permits two mapped Flash segments. An initial image
with separate SQL text/RO segments asserted before entering the kernel. Keep
the descriptor/boot mapping first, then fill the rounded diagnostic-table gap
with read-only zeros so esptool merges tables, SQL text and SQL RO into one
second segment. The image auditor requires exactly two mappings, correct
64 KiB image/address congruence, exact ELF bytes and the zero padding. It
rejects other Flash functions, unresolved symbols, RTOS linkage, hardware FP
in this mode, and unprefixed allocation/time fallback symbols.

## Runtime fixture and finite budget

Run SQL on CPU0's retained bootstrap after the 300-round native soak and the
64-message IPI fixture. Both periodic timers are disarmed and the peer has
completed its work. MIE remains enabled. Each of two sessions checks thirteen
statements: integer/REAL/64-bit arithmetic, UTC dates, omitted localtime,
CREATE, BEGIN/INSERT/COMMIT, SUM and COUNT. Check actual open-function PC,
runtime identity and complete heap recovery after each shutdown.

The 64-bit host-derived quotas were insufficient on RV32: a UTC query exhausted
the 64-byte class, then CREATE exhausted the 32-byte class. Increase those
class quotas to 64, giving `24,12,64,64,64,4,8,12,8,1`. The requested parent grows
from 50,640 to 57,104 bytes but still occupies one 65,536-byte buddy. Keep this
as an explicit experimental profile, without fallback to larger classes or
unbounded growth. Fixed native peaks are `20,10,22,23,16,3,6,8,3,0`.

Paint unused CPU0 bootstrap stack from the 16-byte lower guard to the caller's
SP before SQL, with a leaf assembly helper. Afterwards scan volatile words
and report the deepest changed word. The fixed fixture observed 6,472 bytes,
leaving 1,704 bytes above the guard, or 1,544 after reserving a 160-byte trap
frame. Pattern scanning is an observation, not a formal bound: untouched
frames, pattern collisions, arbitrary SQL recursion and SQL-time preemption
remain outside this evidence. Static C stack-size sections report a largest
single frame of 768 bytes, not a summed or recursive Zig/C callgraph bound.

## Qualification and next gate

Three SQL emulator cases (absent/4/32 MiB) and the nine existing native cases
pass, as do all four device-profile builds. Native SQL keeps 68,096 bytes of
internal heap and a 727,856-byte application inside the 1 MiB factory partition.
Images, loader/config, C manifests, logs and validators are digest-bound.
Retain the exact loader/quota failures alongside successful measurements.

This is a CPU0 bootstrap fixture, not a `sqld` task/RPC, production VFS,
persistent storage, preempted SQL or physical timing qualification. The VFS's
time/randomness remain deterministic. The next gate is physical Tab5 boot,
PSRAM/cache/SMP checks and repeated SQL/heap/stack observations before any
push. Then run both ordinary and Native CI on the published revision. Local
success does not substitute for either physical or remote-CI evidence.

[Source-bound measurements](../measurements/2026-10-26-native-sqlite.md).
