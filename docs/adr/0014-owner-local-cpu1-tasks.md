# ADR 0014: Independent CPU1 task runtime and task-context service work

- Status: accepted
- Date: 2026-10-25

## Decision

Reuse the RV32 runtime on CPU1 with its own scheduler, images, handles, and
two fixed 4 KiB task stacks. Its lower-priority bootstrap supplies the WFI idle
context. CPU0 retains its existing runtime. Each CPU mutates only its own
policy and saved frames, from an outermost trap tail with MIE clear. CPU1's
initialization and post-window reaping also execute on CPU1 while quiescent.
There is no shared run-queue lock or task migration.

The earlier interrupt-only echo remains a regression scenario. The new mode
moves response validation/transformation/publication onto CPU1's service task
stack. Its IPI tail only acknowledges the level, drains a fixed event budget,
applies stop events, and selects a saved frame. ECALLs use the same scalar ABI
and trampoline as CPU0; hart-local dispatch chooses the appropriate runtime.

The service checks its current handle and hardware CPU ID. It wakes a local
observer task and waits for its acknowledgement before running a bounded
payload callback. The observer also checks CPU ID and handle and preserves a
stack canary. This extra handshake is a context-switch test fixture rather
than a production requirement on every service request.

## Owner identity and remote delivery

Task handles remain owner-local slot/generation values. Two different owners
can produce the same encoded handle. A remote reference therefore includes
the destination owner/endpoint; a bare handle does not identify its CPU.
The `notify` task call remains local. Separate inboxes explicitly target CPU0
and CPU1 and resolve generations only on the destination owner.

CPU0 posts CPU1 request doorbells through the second inbox. Its task-side and
trap-tail submissions mask local handling across enqueue and assertion, so
they cannot reenter the single CPU0 producer. CPU1's response inbox is
produced only by the service task in this mode. The interrupt tail must not
also produce responses into that endpoint. The prior interrupt echo mode
uses its own mutually exclusive producer context.

After a bounded task-work budget, queued requests can remain even when their
event metadata was already coalesced and consumed. The service retains that
local work with a self-notification before waiting again. A hardware pulse
with no remaining inbox record would not itself recreate the task event.

The new scenario submits a stale generation to each inbox. Owner delivery
rejects it without changing a valid replacement or the opposite CPU's policy.
Host tests exercise two policies with identical local handles and verify that
draining one inbox cannot wake or change pending bits on the other owner.

## Frames, idle, and termination

CPU1 may now be interrupted on either native task stack or its IDF-supplied
bootstrap stack. Frame validation must use the current registered runtime
image; the old interrupt-only check against the bootstrap bounds is
insufficient. The trap tail restores the selected task's bounds and saved
integer/return state. Initial frames are seeded from the first captured IPI.

The idle foreground uses the existing masked exit-check/WFI protocol. A stop
IPI injects the high-bit stop event into both CPU1 tasks. Each exits through
the normal trampoline; after both are terminal, the runtime selects the
captured bootstrap and marks it finished. Only then does the native window
restore IDF. CPU1 validates both completion codes and stack addresses, reaps
the two tasks, registers an unexecuted replacement, and rejects its old handle.
CPU0 reads the finalized report only after acquiring the producer's `done`.

Payload callbacks check a local marker against the service stack bounds for
every processed request. This distinguishes task-context execution from the
old interrupt-stack echo, independently of merely observing a nonzero count.

## Untimed CPU1 policy

CPU1 still has no native periodic timer in this stage. A runtime-local
`sleep_enabled` option defaults to true for existing CPU0 users; CPU1 sets it
false. SLEEP returns the sign-extended `not_supported` status (-5) before
changing task state. The service exercises that result through a real ECALL.
Host coverage verifies that rejecting sleep preserves the running caller.

CPU1's policy tick count stays at zero because no elapsed ticks are applied.
Event waits, local notification, yield, current-handle queries, and exit work
normally. CPU1 selection is driven by IPIs and cooperative task calls; this
does not qualify timer preemption, timed waits, or long-work fairness without
an interrupt/yield boundary. Those require an actual CPU1 clock contract.

## Validation and boundaries

Run the same 64-message duplex protocol on both owner runtimes. CPU0 still
exercises 32 preposted replies and 32 registered waits. CPU1 processes all
payloads on its native service stack and repeatedly switches to the observer.
Both CPUs finish their native tasks, and the existing checks restore CPU0's
normal IDF task execution and CPU1's normal IDF IPC callback. The older
one-way and interrupt-echo scenarios remain in the same smoke boot.

Report trap-return selections separately from actual changes of selected
slot. Also count IPIs that captured an executing CPU1 task rather than its
idle bootstrap. The stack canaries, payload checks, and completion records
provide the behavioral check; these counters are not throughput benchmarks.

IDF still supplies boot and the CPU1 launch task. CPU1 tasks are integer-only;
opt-in FP state, periodic preemption, dynamic stack allocation, migration,
permanent interrupt ownership, cancellation, rights, buffer leases, and Flash
pause/resume remain later contracts. The new test adds 8 KiB of fixed native
CPU1 stacks. Physical qualification remains distinct from emulator success.
