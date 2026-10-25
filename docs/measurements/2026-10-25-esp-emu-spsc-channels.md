# ESP-EMU event-driven SPSC request/completion smoke

- Date: 2026-10-25
- Firmware commit: `32867f2e43d78ef8a1dfcaa95c0979363e20d82b`
- Emulator: official ESP-EMU v0.50.0, ESP32-P4 revision-3 profile
- ESP-IDF host: v5.4.4
- Platform ABI: 5; channels use the existing experimental event ECALLs

## Result

Two native integer Zig tasks exchanged 64 request/completion pairs through
two capacity-3 SPSC channels. The client kept a four-request window; the
service's initial two-tick sleep forced queue saturation. A nonblocking send
rejected the fourth queued request without overwriting unread data, then a
blocking send resumed after the service released space.

Channel payload progress used event waits rather than polling. The kernel
observed 64 registered waits for readable data and 61 for writable space.
Preposted notifications were allowed to coalesce; each wake caused another
queue check. All sequence numbers and transformed payloads matched, with
completion checksum 504,750,560. Both workers retained stack canaries and
returned through the normal task-exit trampoline.

Both empty rings were seeded at `usize.max - 1` before task execution. Each
published and consumed 64 values, crossing the real RV32 counter boundary
and ending at counter value 62 with no queued items. This exercises the
non-power-of-two capacity across wrap, not just ordinary slot reuse.

```text
ipc_messages=64
ipc_full_rejections=1
ipc_readable_waits=64
ipc_writable_waits=61
ipc_checksum=504750560
ipc_counters_wrapped=1
ipc_syscalls=384
ipc_timer_interrupts=3
ipc_idle_runtime_ticks=3
ipc_exit_code_0=53
ipc_exit_code_1=59
ipc_reaped=2
native_ipc=ok
timer_restoration=ok
native_timer=ok
nihos: core smoke complete
```

The shared lifecycle harness checked both terminal completion codes and
reaped both tasks. It then registered an unexecuted replacement and rejected
notification through the old generation handle. No extra worker stacks were
added; the scenario reuses the harness's two fixed 4 KiB stacks.

The same committed boot passed the 100,000-message IDF-hosted SMP mailbox,
synchronous native context switch, repeated native timer lease, integer and
RV32F preemption, host FP-bank restoration, live task lifecycle, masked event
waits, and final IDF callback-timer restoration.

## Host regression and failure contracts

Strengthening the earlier capacity-3 wrap test first reproduced a real ring
bug: after three writes across integer wrap, the expected second value 42
was replaced by 43. `counter % capacity` aliased unread slots. The correction
uses separate owner-private slot positions while retaining wrapping published
counters for occupancy and release/acquire transfer. Each position shares a
cache-line group with its own writer's publication counter.

Debug and ReleaseSafe each passed all 41 host tests. The two-thread ring test
exchanged 100,000 ordered values at capacity 3 and another 100,000 at capacity
64, with both runs seeded near integer wrap. New channel tests cover:

- publication and slot release before notification;
- full rejection without notification or overwrite;
- stale events and publication/release in the check-to-wait gap;
- wait errors retaining an unqueued send or an empty receive;
- notification errors retaining the commit result and any received value;
- one-bit event reservations, including bit 31.

ZLint reported zero errors and warnings across 23 files. Formatting,
ShellCheck, RV32 architecture compilation, and the C/Zig/Rust ABI probe passed.
Both physical revision-1 and emulator revision-3 ESP-IDF builds passed. The
physical-target application is 399,440 bytes (`0x61850`), leaving 62 percent
of the 1 MiB application partition free. Its increase of 4,064 bytes over the
event-only image includes test workers and diagnostics; it is not an isolated
production cost for the channel helper.

## Boundary

No physical Tab5 was flashed. Both native channel endpoints ran on CPU0;
the emulated cross-core mailbox still used polling under IDF task placement.
CPU1 event forwarding/IPI and cross-core blocking remain unqualified.

The 384 ECALLs and three timer interrupts describe this functional scenario,
not a throughput or latency benchmark. Native posting currently notifies on
every successful push and pop. Batching or notification suppression needs
separate correctness work and measurements before frame/audio workloads.
The channel uses fixed storage and no heap allocation or queue locks.

There is no close/cancellation or automatic dead-peer wakeup yet. A successful
queue operation cannot be rolled back if its subsequent notification fails;
the API reports that commit boundary explicitly. Resource reclamation,
untrusted request validation, permanent services, physical completion timing,
and game-load interference remain later work. See
[ADR 0011](../adr/0011-event-driven-spsc-channels.md).
