# ADR 0009: Scalar task calls and explicit completion/reaping

- Status: accepted
- Date: 2026-10-25

## Decision

Connect the scheduler to live task calls through a small machine-mode ECALL
ABI. `task_control.zig` implements portable policy changes and reply encoding;
`task_runtime.zig` validates and captures RV32 frames, advances ECALL's `mepc`
by four, stores the reply, and selects a resumable context. Task-side Zig
wrappers use one C-ABI assembly gateway. No call accepts a task-supplied
pointer.

The gateway puts the call number in `a7` and one scalar argument in `a0`.
ADR 0010 extends this with an `a1` payload for notifications; the calls below
require that payload to be zero.
Replies occupy `a0/a1`, matching a C-ABI 64-bit return. Negative status codes
are sign-extended; successful 32-bit handles have a zero high word, including
handles whose generation makes bit 31 of the low word nonzero.

| Number in a7 | Operation | Argument in a0 | Successful result |
| --- | --- | --- | --- |
| `0x4e490000` | yield | zero | zero after resuming |
| `0x4e490001` | sleep | nonzero duration in ticks | zero after waking |
| `0x4e490002` | wake | encoded task handle | zero |
| `0x4e490003` | exit | signed 32-bit exit code | caller never resumes |
| `0x4e490004` | current | zero | encoded current handle |
| `0x4e490005` | ticks | zero | full 64-bit scheduler time |
| `0x4e490006` | block | zero | zero after explicit wake |

Invalid calls, invalid arguments, stale handles, and invalid task states
produce distinct scalar errors. Compile-time checks keep the assembly call
numbers synchronized with the Zig enum. A blocked or sleeping frame retains
its reply and resumes after ECALL when selected again. Timer interrupts leave
the interrupted `mepc` unchanged.

## Terminal state and handle lifetime

A task entry now returns a signed exit code. The assembly trampoline converts
that return into EXIT; it never returns to an arbitrary address. Exiting marks
the current task `exited`, removes it from selection, and retains its exit
code and runtime accounting. Wake, block, and sleep cannot revive it.

Only explicit reaping releases the scheduler slot and saved image. Reaping
runs on a kernel/interrupt stack while no other core owns that task's stack or
FP state. It rejects live tasks. Reusing a slot increments the 16-bit
generation; exhausted generations retire a slot rather than wrapping and
reviving ancient handles. This needs no additional per-slot allocation.

The native runtime checks that every captured/selected integer frame is
aligned and completely inside its registered stack bounds. A registered,
lower-priority bootstrap supplies the idle context while all workers wait.
Its real frame is captured at the first timer trap, before it can be resumed
by the runtime. A permanent kernel will provide its own idle task instead.

## Target scenario

Run two integer Zig tasks with the same timer lease as ADR 0007. One sleeps
for five ticks, then blocks until its peer explicitly wakes it, and returns
17. The peer first sleeps for two ticks, forcing both workers to be asleep
together, then makes progress while the first task waits. It wakes the blocked
task, verifies that wake rejects the exited task, and returns 37.

Verify the accepted kernel sleep deadline, resumed tick, stack canaries,
peer progress, idle runtime, exit codes, and host interrupt restoration.
After both tasks exit and native execution is quiescent, reap both slots,
register a replacement without executing it, and verify that the old handle
cannot affect its ready state. Unknown calls and zero-duration sleep are
also exercised through real ECALLs.

## Boundaries

This is an experimental native task ABI in a shared, trusted machine-mode
domain. Generations prevent stale references; they are not access-control
secrets. PMP/user-mode isolation, capability rights, cross-core wakeup/IPI,
join/cancellation, stack-pool allocation, and concurrent reaping require later
contracts. The current runtime is serialized at the outermost trap tail with
MIE cleared; initialization and post-window reaping use a quiescent kernel
bootstrap context. Physical hardware qualification remains separate.
