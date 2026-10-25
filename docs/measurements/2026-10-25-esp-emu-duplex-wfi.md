# ESP-EMU duplex IPI and CPU1 WFI service smoke

- Date: 2026-10-25
- Firmware commit: `1b072fdf0aa5da61dbb516bee3a5d2ed4acaa288`
- Emulator: official ESP-EMU v0.50.0, ESP32-P4 revision-3 profile
- ESP-IDF host: v5.4.4
- Platform ABI: 5; native service borrowing remains a private bring-up ABI

## Result

Both cores executed bounded native interrupt windows. CPU0 retained its
native task scheduler; CPU1 ran one integer echo service and parked its
foreground with WFI. Requests and replies used two capacity-3 SPSC rings;
CPU1-to-CPU0 event metadata used the existing capacity-4 owner inbox.
Neither payload processing nor the test's wait-registration gate used queue
polling on CPU1.

The client completed all 64 ordered request/completion pairs, with checksum
3,136,933,344. Even requests notified CPU1 before sleeping for one CPU0 tick;
their 32 replies were pending when the client called WAIT. Odd requests were
held in a single CPU1-owned pending slot until CPU0 registered its wait and
asserted another IPI, producing 32 actual blocked waits and wakeups. This gate
advanced by interrupt, not by spinning on a shared flag.

```text
duplex_messages=64
duplex_registered_waits=32
duplex_preposted_waits=32
duplex_cpu0_ipi_interrupts=65
duplex_cpu1_ipi_interrupts=66
duplex_cpu1_wfi_entries=66
duplex_stop_interrupts=1
duplex_delivered=65
duplex_rejected=1
duplex_checksum=3136933344
duplex_syscalls=99
duplex_timer_interrupts=32
duplex_reaped=2
duplex_both_hosts_restored=1
native_duplex_events=ok
timer_period_us=1000
timer_ticks=128
timer_elapsed_us=128042
timer_restoration=ok
native_timer=ok
nihos: core smoke complete
```

CPU0 accepted 65 notifications including the observer's completion and
rejected one intentionally stale generation. Both native tasks preserved
their stack canaries, returned completion codes 73/79, and were reaped. The
shared harness registered an unexecuted replacement and rejected the old
handle as in the earlier lifecycle scenarios.

CPU1 executed WFI 66 times and processed one stop IPI before leaving its
window. The stop flag was set by the service interrupt tail, so CPU0 could
not finish the join merely by writing an exit flag and skipping interrupt
delivery. CPU1 readiness was published only after its native vector was
installed. Timeout/partial-preparation paths also request stop and join.

Both shims checked their original route, vectored flag, threshold, and
enabled mask; CPU1 also checked its original foreground stack bounds. A real
IDF yield reason was submitted to CPU1 during native ownership and retained
for replay. After both windows returned, an ordinary IDF CPU0 task executed,
and `esp_ipc_call_blocking` completed a callback in CPU1's normal IDF IPC task.
The final IDF timer then delivered all 128 callbacks. These are scheduling
and restoration checks, not counters for every internal IDF reason branch.

The same committed boot passed the earlier IDF SMP mailbox, synchronous
context switch, repeated timer lease, integer/RV32F preemption, IDF FP-bank
restoration, lifecycle, event waits, CPU0 channels, and one-way owner-IPI
scenarios. The original one-way CPU1 polling scenario remains as a separate
regression test; the duplex scenario uses native CPU1 interrupts and WFI.

## Other checks and resources

Debug and ReleaseSafe each passed all 49 host tests. Three new park tests
model stop arriving before the masked check, notification in the check-to-wait
gap, and restoration of an already-masked caller. They validate the ordering
protocol; the emulator separately executes the CSR and WFI instructions.
ZLint reported zero errors and warnings across 30 Zig files. Formatting,
ShellCheck, RV32 architecture compilation, the C/Zig/Rust ABI probe, and both
physical revision-1 and emulator revision-3 builds passed.

The physical-target application is 412,096 bytes (`0x649c0`), leaving 61
percent of its 1 MiB partition free. Its 6,080-byte increase includes test
workers, diagnostics, and the CPU1 resource/restoration adapter. It is not an
isolated production cost for WFI or reverse notification.

The CPU0 workers reuse the existing two fixed 4 KiB stacks. CPU1's foreground
uses the 4 KiB stack from the IDF task launcher and its native handler uses
the already allocated per-core 2 KiB interrupt stack. No new native worker
stack or heap allocation is introduced in the interrupt path. IDF still owns
launch-task deletion and eventual stack reclamation.

## Boundary

No physical Tab5 was flashed. WFI instruction entries do not measure sleep
duration, energy savings, or physical interrupt latency; WFI is permitted to
return spuriously. The 32 CPU0 timer interrupts come from the deliberately
timed preposted-reply fixture and are not a throughput benchmark.

CPU1 boot and launch still come from IDF. It has one bounded integer echo
service, not native task switching/preemption or an FP context policy. The
echo calculation is intentionally short interrupt work; general services need
scheduled task contexts. Permanent IPI ownership, cancellation, buffer leases,
Flash pause/resume, hardware qualification, and frame/audio-load interference
remain later work. See [ADR 0013](../adr/0013-duplex-ipi-and-wfi-service.md).
