# ADR 0020: Native owner inboxes and WFI with no periodic wake fallback

- Status: accepted; emulator qualified, physical qualification deferred
- Date: 2026-10-25

## Decision

Connect the existing SPSC ring, remote event inbox, software doorbell, scalar
event wait and masked `park.once` to the permanent native owners. No ESP-IDF
reason array or interrupt resource lease is used in this backend. Each hart
owns a dedicated level source and routes it to non-vectored CLIC input 17:

| Target | Software register | Matrix source | CLIC input |
| --- | --- | ---: | ---: |
| CPU0 | HP_SYSTEM_CPU_INT_FROM_CPU_0, `0x500e5010` | 79 | 17 |
| CPU1 | HP_SYSTEM_CPU_INT_FROM_CPU_1, `0x500e5014` | 80 | 17 |

Both startup entries clear MEXSTATUS.WFFEN using the pinned P4 definition, so
the wait instruction uses interrupt wait rather than event-wait mode. The
existing rev1/rev3 threshold selection and active-trap mcause restoration
remain unchanged.

## Transition from the preemption fixture

Retain the 300-round preemption/lifecycle checks as the first stage. Then
publish a stop request for the busy workers. Each returns through the normal
exit trampoline; its owner verifies the exit code and reaps its stack/frame.
The owner reuses the existing lifecycle stack for a protocol task, with no
new heap or stack allocation. Explicit phase/task-kind enums describe the
transition through lifecycle, preemption, IPI protocol and completion.

The bootstrap's priority changes from 0 to 1; the protocol task has priority
0. `setPriority` is owner-only, checks generation and range, preserves state,
and takes effect at the next scheduling decision. Its host regression test
covers blocked/current/exited/stale handles. The owner makes a fresh decision
after creating the protocol task, so a runnable worker cannot be stranded
behind a bootstrap entering WFI.

At this transition the owner disarms its timer alarm, clearing pending alarm
status while retaining the free-running counter. Subsequent ECALL/IPI paths
still account elapsed time from that counter but do not rearm periodic
alarms. A timer IRQ in this phase fails the fixture. This is an IPI-only idle
qualification interval, not a general tickless scheduler for arbitrary timed
sleepers.

## Queue and wake ownership

There is one eight-record inbox per owner, with one protocol-task producer
on the peer and one interrupt-stack consumer on the owner. A post publishes
the record before asserting the doorbell. The IRQ acknowledges the level
before acquiring queue data, drains at most four records, and uses the shared
inbox's reassertion rule if records remain. Only the owner calls its policy's
notify/select operations; no peer reads or writes the mutable scheduler.

The client and service exchange 64 request/completion pairs. Each direction
has an atomic sequence and checked scalar payload, with one outstanding
message, plus a generation-checked event notification. This fixture verifies
ordering and wake delivery; it does not stress a saturated native inbox.
Existing host inbox tests retain full/budget/reassert/stale-target coverage.

For each send, the producer waits for the target to publish a *new* WFI entry
with its handling masked. The receiving protocol task is already waiting on
its event, so the bootstrap is the only runnable context. `park.once` checks
the persistent completion condition with MIE clear, executes WFI, then
restores the exact prior mstatus. A level pending before or during WFI can
resume the wait even while handling is masked; restoration admits the IPI
and selects the woken protocol task.

The first entry on each hart deliberately waits, with MIE still clear, for
the peer's doorbell to become pending *before* executing WFI. This provides
a target test of the check-to-wait arrival case, independent of the existing
host model. Other entries permit ordinary arrivals. WFI is an architectural
wait instruction; counts here do not measure physical sleep duration or
power savings, and are not exhaustive race qualification.

Each protocol task exits normally and is reaped before its owner publishes
completion. A shared atomic fetch-or bitmask makes the second finisher set
the persistent all-done condition without a two-flag store/load race. An
empty-inbox completion IPI also wakes a peer already parked after its own
task exited. Such a doorbell can coalesce with a message IPI. Both native
entries remain in WFI after the bounded fixture completes.

## Qualification and next boundary

Success requires both 300-round task evidence and two distinct IPI records:
64 sent, received, delivered and woken per owner; at least 64 IPI captures of
the parked bootstrap; at least 64 WFI returns; one forced pending-before-WFI
case; no rejected or queued messages; and unchanged timer IRQ baselines.
The runner exits on the final IPI/idle marker, not the preceding soak marker.
Fifteen log-validator tests reject absent owner evidence, timer fallback,
incomplete delivery, undrained queues and missing pending-before-WFI probes.

Emulator and physical profiles still link through the IDF-free native ELF
script, and the app image audit still permits only SRAM code/data and two
read-only Flash metadata mappings. Physical rev1, FP ownership, migration,
PSRAM, display, protection domains and production idle/power behavior remain
separate gates. Native FP save/restore is the next integration stage.

## Primary references

- [ADR 0019: Permanent native task owners](0019-permanent-native-task-owners.md)
- [ADR 0013: Earlier bounded duplex IPI/WFI fixture](0013-duplex-ipi-and-wfi-service.md)
- [Official P4 software interrupt registers](https://github.com/espressif/esp-idf/blob/v5.4.4/components/soc/esp32p4/register/hw_ver1/soc/hp_system_reg.h)
- [Official P4 interrupt source enumeration](https://github.com/espressif/esp-idf/blob/v5.4.4/components/soc/esp32p4/include/soc/interrupts.h)
- [Official P4 WFE control](https://github.com/espressif/esp-idf/blob/v5.4.4/components/riscv/include/esp_private/interrupt_clic.h)
- [Official CSR encoding, MEXSTATUS_WFFEN](https://github.com/espressif/esp-idf/blob/v5.4.4/components/riscv/include/riscv/encoding.h)
