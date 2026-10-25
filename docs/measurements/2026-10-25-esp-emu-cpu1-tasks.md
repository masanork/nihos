# ESP-EMU independent CPU1 native tasks and service-context work

- Date: 2026-10-25
- Firmware commit: `4f46c45054bbb480588b109f796a47dd0239f1fd`
- Emulator: official ESP-EMU v0.50.0, ESP32-P4 revision-3 profile
- ESP-IDF host: v5.4.4
- Platform ABI: 5; native task calls add unsupported-operation status -5

## Result

CPU0 and CPU1 used separate instances of the native task runtime. CPU0
retained its timer-driven client/observer tasks. CPU1 ran a service task and
a local observer on distinct fixed 4 KiB native stacks, with a lower-priority
WFI bootstrap as idle context. IPI delivery and ECALLs changed only the
runtime owned by their hardware core.

All 64 request/completion pairs passed. A local stack marker was checked
against the CPU1 service stack for every processed request, confirming that
payload validation, transformation, and response publication moved out of
the interrupt tail. The observer completed 65 acknowledgement rounds, and
both CPU1 tasks checked their hardware CPU ID, current handle, and stack
canaries. A real CPU1 SLEEP call returned not-supported without suspending
the service.

```text
cpu1_task_messages=64
cpu1_task_payloads=64
cpu1_task_observer_rounds=65
cpu1_task_syscalls=397
cpu1_task_selections=463
cpu1_task_switches=263
cpu1_task_ipi_captures=1
cpu1_task_events_delivered=65
cpu1_task_stale_rejected=1
cpu1_task_reaped=2
cpu1_task_replacement_generation=2
cpu1_task_wfi_entries=34
cpu1_task_registered_waits=32
cpu1_task_preposted_waits=32
cpu1_task_checksum=3136933344
cpu1_task_both_hosts_restored=1
native_cpu1_tasks=ok
timer_period_us=1000
timer_ticks=128
timer_elapsed_us=128043
timer_restoration=ok
native_timer=ok
nihos: core smoke complete
```

The CPU1 tail returned 463 selected contexts, of which 263 changed the
selected slot, including transitions through idle. One IPI captured an
executing native CPU1 task rather than the bootstrap. The frame path validated
the current runtime image's bounds and restored the selected task's bounds
and integer/return state. The old interrupt-only bootstrap-bound check was
insufficient once CPU1 could execute on other stacks; the new mode delegates
that validation to the runtime.

CPU0 observed 32 preposted replies and 32 registered waits, with checksum
3,136,933,344. CPU1's inbox accepted 65 valid request notifications and
rejected one stale generation. CPU0's response owner also rejected the stale
generation submitted by the service. The two inboxes remain separate owner
namespaces even when their local slot/generation values match.

After a stop IPI, both CPU1 tasks returned normal completion codes 83/89 and
the runtime selected its captured idle bootstrap. CPU1 restored IDF, checked
stack/interrupt state, reaped both task records, registered an unexecuted
generation-2 replacement, and rejected the old handle. CPU0 also completed
and reaped its client/observer pair through the shared lifecycle harness.
The finalized CPU1 report was read only after producer quiescence.

An ordinary CPU0 IDF task and a blocking CPU1 IDF IPC callback executed after
restoration, followed by all 128 IDF timer callbacks. The same boot retained
all previous mailbox, timer, context, integer/FP preemption, lifecycle,
event/channel, one-way IPI, and interrupt-echo duplex regression scenarios.

## Host checks and resources

Debug and ReleaseSafe each passed all 51 host tests. Added coverage verifies
that a timerless owner rejects sleep without changing its running task, and
that separate owner inboxes cannot wake each other's policy even when local
handles have identical encodings. ZLint reported zero errors and warnings
across 31 Zig files. Formatting, ShellCheck, RV32 architecture compilation,
the C/Zig/Rust ABI probe, and both physical revision-1 and emulator revision-3
ESP-IDF builds passed.

The physical-target application is 418,688 bytes (`0x66380`), leaving 60
percent of its 1 MiB partition free. Its 6,592-byte increase over the previous
image includes the additional task scenario, counters, and checks. The new
CPU1 fixture adds 8 KiB of fixed internal-RAM native task stacks. Its idle
foreground continues using the IDF launch stack and the existing per-core
interrupt stack. No heap allocation or run-queue lock is used in native
selection, event delivery, or the payload callback.

## Boundary

No physical Tab5 was flashed. CPU1 tasks are integer-only and their scheduler
tick count remains zero. Selection is driven by IPIs and cooperative calls;
CPU1 periodic preemption, timed waits, and FP context switching remain open.
The observer handshake tests switching and is not a required production IPC
overhead. These functional counters do not establish throughput, latency,
energy savings, or frame/audio-load performance.

IDF still owns boot and initial CPU1 launch. Owner migration, dynamic stack
pools, general cancellation, permanent interrupt ownership, rights checks,
buffer leases, and cross-core Flash pause/resume need separate contracts.
See [ADR 0014](../adr/0014-owner-local-cpu1-tasks.md).
