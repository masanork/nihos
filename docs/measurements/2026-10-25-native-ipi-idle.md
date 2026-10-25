# Native inbox/IPI wake from WFI without periodic timer fallback

- Date: 2026-10-25
- Firmware implementation: `4a65e636ce247fcded7395c21ae6303af113779c`
- Zig 0.17.0, ESP-IDF v5.4.4 loader only, ESP-EMU v0.50.0
- [Artifact digests and machine-readable observations](2026-10-25-native-ipi-idle.json)
- [ADR 0020](../adr/0020-native-ipi-and-interrupt-wait.md)
- Reproduce: `sh tools/run-native-smoke.sh`

## Result

One emulated revision-3 ROM boot, with no PSRAM, first completed the existing
300-round task preemption/lifecycle checks. The owners then stopped and
reaped their busy workers, lowered bootstrap priority, started one protocol
task each, and disarmed the periodic alarms while retaining the free-running
timer counters. The final native IPI/idle marker was reached.

The client and service exchanged 64 ordered request/completion pairs through
the existing SPSC inbox and task event ABI. Each send waited for a new WFI
entry on the target, so the notification resumed a waiting protocol task via
its owner's IPI dispatcher. Each protocol task returned its expected exit
code and was reaped before owner completion was published.

| Final IPI interval observation | CPU0 | CPU1 |
| --- | ---: | ---: |
| Messages sent / received | 64 / 64 | 64 / 64 |
| Inbox delivered / woken | 64 / 64 | 64 / 64 |
| Rejected / remaining queue records | 0 / 0 | 0 / 0 |
| IPI captures of parked bootstrap | 64 | 64 |
| Total IPIs | 65 | 64 |
| WFI entries / returns | 64 / 64 | 65 / 65 |
| Forced pending-before-WFI cases | 1 | 1 |
| Timer IRQ baseline / final count | 901 / 901 | 901 / 901 |

The empty-inbox completion notification can add an IPI/WFI return or
coalesce with a message IPI. Total IPI and WFI counts therefore need not be
identical across owners. The timer counts were unchanged during the complete
IPI interval. At each hart's first idle entry, MIE stayed clear until the
peer's level was already pending, then WFI ran and returned before interrupt
handling was restored. Thus the test covered an arrival before WFI without
relying on a subsequent periodic alarm.

## Resources and checks

Both revision profiles passed the image audit. Native text was 24,030 bytes;
SRAM reservation including all fixed stacks, policy and inbox state was
83,712 bytes (81.75 KiB), leaving 46.25 KiB in the deliberately limited
128 KiB region. No extra task stack or heap was allocated for the protocol.
The app image remains 65,616 bytes including stock-loader Flash alignment.

All 52 host tests passed in Debug and ReleaseSafe, including the new
owner-only priority-change contract and extended timer-disarm assertions.
ZLint found zero errors/warnings across 34 files; ShellCheck, hosted RV32
contracts and final native ELF links for both profiles passed. Fifteen log
validator tests passed. The validator requires the new IPI records and final
marker, and rejects timer fallback, missing owner delivery/idle evidence,
undrained queues and an absent pending-before-WFI probe.

The earlier task fixture still showed 300/300 busy-task timer captures on
CPU0 and 300/299 on CPU1, with two lifecycle generations reaped per owner
before the IPI transition. Existing stack/MIE/frame and runtime-accounting
checks continued through the new owner transitions and IPI/ECALL paths.

## Evidence boundary

Physical qualification remains deferred at the user's request; no device was
accessed. This is an emulator test of instruction/control flow and bounded
message delivery, not a measurement of sleep duration, power savings,
throughput, saturated queues or every race interleaving. It does not add a
general tickless timed-sleep policy. Native FP ownership, migration, PSRAM,
display and protection domains remain separate work. Remote workflow results
are separate from this local measurement.
