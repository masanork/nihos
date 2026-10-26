# 0039: Runtime C task identity before library initialization

Status: accepted for host and native emulator qualification, 2026-10-26.

`nih_task_identity()` returns a nonzero u32 stamp for an active current task,
even before a C pool is opened. Bits 31..24 contain the owner hart, 23..16
the slot and 15..0 the scheduler generation. Unsupported owner/slot values,
generation zero, inactive tasks, unavailable heaps and MIE-disabled native
calls return zero. Existing native slots/generations fit without truncation.

The stamp is stable across explicit pool close/open and changes on scheduler
slot generation reuse. It is runtime-scoped, is not a capability, and is not
stable across reboot. Migration remains unsupported; any later migration API
must revisit identity semantics. The scheduler already retires exhausted
generations instead of wrapping them.

A SQLite wrapper can record this stamp before calling the globally configured
THREADSAFE=0 library, and reject wrong-task entry before touching SQLite state.
Allocator callbacks alone cannot provide that guarantee because an operation
may touch global library state before its first allocation. A library owner
that is force-killed still requires fail-stop/restart handling; allocator
reclamation is not semantic SQLite shutdown.

The C probe checks identity stability through pool operations on both native
harts. The masked-call probe checks that identity returns zero in interrupt
context. Host tests distinguish hart, slot and generation, exercise full-width
boundary values, and verify retirement invalidation. The host oracle uses a
thread-local current slot, and a pthread check verifies that selecting another
host task leaves the calling thread's identity intact. The oracle heap itself
is still single-owner: it is not a concurrent host allocator.

Compiled RV32/ILP32F with 32 MiB PSRAM passes the complete native smoke; all six
architecture ELF variants and host Debug/ReleaseSafe suites pass. No physical
device or native SQLite execution is claimed.

[Source-bound evidence](../measurements/2026-10-26-c-task-identity.json).
