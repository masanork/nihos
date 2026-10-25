# ADR 0010: Latched task events and serialized wait registration

- Status: accepted
- Date: 2026-10-25

## Decision

Give each task 32 coalescing event bits. `notify(handle, bits)` ORs nonzero
bits into the target's pending set. `waitEvents(mask)` consumes and returns
all pending bits matching a nonzero mask. Unmatched bits remain pending.
If nothing matches, checking the pending set and registering the wait are
one serialized kernel operation. A notification can therefore arrive before
or after registration without falling into a check-then-sleep gap.

These operations have bounded constant work after handle lookup, need no
heap allocation, and add three `u32` fields per task: pending bits, wait mask,
and a deferred reply. They do not require a general wait-queue allocator.

## Task ABI and deferred replies

Extend the experimental ADR 0009 scalar ABI with a second argument in `a1`.
Existing calls require that argument to be zero. The C-ABI assembly gateway
accepts number/argument/payload in `a0/a1/a2` and moves them to `a7/a0/a1`.
Both the normal task-return trampoline and direct EXIT clear the payload.

| Number in a7 | Operation | a0 | a1 | Successful reply in a0/a1 |
| --- | --- | --- | --- | --- |
| `0x4e490007` | wait events | nonzero mask | zero | matching bits / zero |
| `0x4e490008` | notify | generation-checked handle | nonzero bits | zero / zero |

All 32 event bits are data. A successful reply with bit 31 set has a zero
high word; an error is a sign-extended negative status. Task-side wrappers
return a tagged result so bit 31 cannot be mistaken for an error.

A waiting task has its own `waiting` state. A matching notification consumes
the matching bits, records a deferred reply, and makes it ready. The runtime
delivers that reply exactly once into its saved `a0/a1` before returning to
task code. Later notifications accumulate separately until the next wait;
they cannot overwrite a reply already selected for delivery.

Nonmatching notifications leave a waiter asleep. Notifications to timed
sleepers or explicitly blocked tasks latch bits without waking them. Raw
WAKE and elapsed time cannot complete an event wait. Exit clears event state;
notify rejects completed or stale handles, and slot reuse starts empty.
Waking a matching receiver requests ordinary priority/round-robin selection;
it does not guarantee an immediate handoff to a lower-priority task.

## IPC and device completion

Use events as doorbells for state stored elsewhere. Repeated posts of the
same bit coalesce, so these flags are neither counted semaphores nor message
storage. Producers publish queue entries before notification; receivers drain
the queue after waking. Existing SPSC queues retain their release/acquire
publication rules. A queue-full policy and the treatment of stale completions
belong to the service protocol.

This establishes the CPU-local wait/notify primitive before wiring graphics,
audio, storage, and future SQLite service completion into the scheduler.

## Validation and boundaries

Host tests cover preposted/coalesced events, masks including bit 31,
nonmatching notifications, repeated delivery, timed sleep/raw wake separation,
exit/reuse, stale handles, and malformed scalar arguments. The bounded native
scenario reuses the lifecycle harness and its two 4 KiB stacks. It exercises
immediate and blocked waits through real ECALLs and timer preemption, checks
stack canaries, rejects terminal notification, reaps both workers, and rejects
a stale notification after slot reuse.

Live policy changes currently run only on CPU0's outermost trap stack with
MIE cleared. The no-lost-wakeup argument depends on that single owner. CPU1
must later submit notifications through an owner mailbox and an IPI/interrupt
path; calling this policy concurrently is unsupported. Native device IRQ
submission also needs its own owner-path integration. Timed event waits,
cancellation, rights checks, user-mode isolation, and physical-device timing
remain separate work. Handles identify tasks; they do not grant isolation
inside the current shared machine-mode trust domain.
