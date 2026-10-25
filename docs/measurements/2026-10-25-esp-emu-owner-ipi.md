# ESP-EMU CPU1-to-CPU0 owner notification and IPI smoke

- Date: 2026-10-25
- Firmware commit: `e4546396813b4c1e94405c2787b399bffd7d595b`
- Emulator: official ESP-EMU v0.50.0, ESP32-P4 revision-3 profile
- ESP-IDF host: v5.4.4
- Platform ABI: 5; IPI borrowing is a private, pinned bring-up boundary

## Result

An IDF-created worker executed on CPU1 while two native integer tasks ran
under CPU0's bounded runtime. The native client submitted 64 requests through
a capacity-3 SPSC ring. CPU1 validated each request, waited for an acquire flag
proving the client had registered its event wait, published the response,
then submitted its notification through a capacity-4 owner inbox and asserted
CPU0's level IPI.

CPU0's native IPI tail acknowledged the hardware before draining the inbox,
validated the target generation, and completed the saved event reply. All
64 client waits resumed with correct response order and payloads. An observer
task received the final completion event. Both native tasks checked stack
canaries and returned exit codes 67/71, then were reaped.

```text
remote_messages=64
remote_worker_cpu=1
remote_registered_waits=64
remote_ipi_interrupts=65
remote_delivered=65
remote_rejected=1
remote_woken=65
remote_checksum=186756576
remote_syscalls=67
remote_timer_interrupts=0
remote_exit_code_0=67
remote_exit_code_1=71
remote_reaped=2
remote_host_scheduler_restored=1
native_remote_events=ok
timer_period_us=1000
timer_ticks=128
timer_elapsed_us=128043
timer_restoration=ok
native_timer=ok
nihos: core smoke complete
```

The owner accepted 65 notifications, woke 65 waiters including the observer,
and rejected one deliberately stale generation. The completion checksum was
186,756,576. There were 65 IPI entries and no timer interrupt entries in this
window. The native timer and task-call paths never drain the owner inbox, so
the observed response delivery depended on the IPI path. Zero timer entries
also exercised initial task-state seeding from an IPI capture.

The CPU1 notification producer was stopped/joined before the native window
ended. The common lifecycle
harness registered an unexecuted replacement and rejected the old handle.
The IPI shim verified the original matrix route and vectored flag; the window
also verified threshold, enabled-mask, and stack-bound restoration.

During native execution CPU1 submitted a real IDF cross-core yield request.
The native tail left IDF's reason array untouched, and the exit shim reasserted
the hardware line after restoring IDF's vector. A newly created IDF task on
CPU0 actually executed after return, followed by all 128 callback-timer ticks.
This demonstrates resumed host scheduling; it is not direct instrumentation
of every IDF reason branch or a qualification of delayed debug/watchdog work.

The same committed boot passed the previous 100,000-message IDF SMP mailbox,
native context switch, repeated native timer lease, integer and RV32F
preemption, IDF FP-bank restoration, task lifecycle, masked events, and
event-driven CPU0 request/completion scenarios.

## Other checks

Debug and ReleaseSafe each passed all 46 host tests. The new owner-inbox tests
cover publication before ringing, malformed/full rejection without ringing,
preposted and registered event waits, bit 31, retaining a deferred reply,
bounded-drain reassertion, and rejecting old/dead targets at delivery. The MMIO
constructor test checks address validation only; host tests do not execute
RISC-V fences or prove physical interrupt delivery.

ZLint reported zero errors and warnings across 27 Zig files. Formatting,
ShellCheck, RV32 architecture compilation, the C/Zig/Rust ABI probe, and both
physical revision-1 and emulator revision-3 ESP-IDF builds passed. The
physical-target image is 406,016 bytes (`0x63200`), leaving 61 percent of its
1 MiB application partition free. Its 6,576-byte increase includes test
workers, resource checks, and diagnostics, not just the inbox primitive.

The native scenario reuses the existing two 4 KiB worker stacks. The CPU1
worker and post-window CPU0 probe use the IDF bootstrap task API and its 4 KiB
stacks. Those tasks are test/oracle infrastructure. Native inbox publication
and draining use fixed storage without allocating or taking scheduler locks.

## Boundary

No physical Tab5 was flashed. This is emulated remote delivery to CPU0's
native owner. CPU1 still uses IDF task creation/affinity and polls requests
and a test-only wait-registration flag. Native CPU1 scheduling and reverse
event forwarding are not implemented, and the native scheduler still has
one owner.

The test deliberately forces registered waits. It is a functional wakeup and
restoration proof, not a latency/throughput benchmark or a frame-load result.
No Flash/cache-off operations occur in the bounded window. Bidirectional
native blocking, service cancellation, rights checks, physical interrupt
latency, and cross-core Flash pause/resume remain separate work. The resource
borrowing and queue ordering contracts, with official IDF source references,
are recorded in [ADR 0012](../adr/0012-owner-inbox-and-borrowed-ipi.md).
