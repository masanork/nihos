# Physical Tab5 native SMP preemption and lifecycle qualification

- Date: 2026-10-25
- Firmware commit: `715da607c2eafe612ea53dea62e03a85192938b4`
- Board: M5Stack Tab5, ESP32-P4 revision 1.3, USB Serial/JTAG
- ESP-IDF: v5.4.4; physical revision-1 build, platform ABI 5
- Application: 423,936 bytes (`0x67800`)
- Application SHA-256: `52677a1af1265a4f1cc3503590b5c2e0b63f007d5c5e77785e224f2f43f18b5b`
- [Machine-readable results for all three boots](2026-10-25-tab5-native-smp-preemption.json)

## Result

Flashed the physical build, verified the write through esptool, and captured
three consecutive USB RTS-reset boots of the same committed firmware. Each
reached `nihos: bootstrap complete` after the full native core tests, DMA,
display/vsync, and touch initialization. These were resets with power
connected, not power-loss or cold-start tests. The user also confirmed the
usual display pattern was visible.

CPU0 and CPU1 ran independent native runtimes with separate Timer Group
channels. CPU1's service slept while its peer executed a loop without ECALL,
yield, or time queries. Its timer tail woke the service and preempted that
peer so the service could resume at the accepted deadline.

| Observation | Boot 1 | Boot 2 | Boot 3 |
| --- | ---: | ---: | ---: |
| CPU1 timer interrupts | 37 | 37 | 37 |
| CPU1 timer captures of a native worker | 6 | 6 | 6 |
| CPU1 caught-up ticks | 2 | 2 | 2 |
| CPU1 elapsed / summed runtime ticks | 39 / 39 | 39 / 39 | 39 / 39 |
| CPU1 sleep start / deadline / resumed | 4 / 9 / 9 | 4 / 9 / 9 | 4 / 9 / 9 |
| Non-yielding loop iterations | 149,577 | 149,568 | 149,541 |
| Timed duplex messages / validated payloads | 64 / 64 | 64 / 64 | 64 / 64 |
| Timed CPU1 actual slot changes | 265 | 265 | 265 |
| CPU0 timer interrupts during timed duplex | 36 | 36 | 36 |
| CPU1 completions reaped | 2 | 2 | 2 |
| Both hosts restored | 1 | 1 | 1 |

Every boot reported `cpu1_probe_timer_wake=1` and
`native_cpu1_timer_preemption=ok`. The delayed first alarm accounted for two
missed ticks without resetting the original phase. Task/idle runtime sums
matched the CPU1 elapsed count before reaping. CPU1 time remains owner-local
and interrupt-accounted; five sleep ticks do not promise a minimum 5 ms from
an arbitrary counter phase.

The older untimed CPU1 scenario also passed, including its unsupported-SLEEP
check, 64 payloads, 65 observer rounds, stale-generation rejection, and two
reaps. It observed zero IPIs capturing an executing native worker on these
boots, unlike the historical emulator run. That incidental counter is not
the timer-preemption proof; the timed probe independently requires and
observed timer captures and a timer-driven wake.

## Two failures exposed by physical execution

The original `a9b67e0` image passed CPU0 integer and FP preemption but stopped
at the subsequent lifecycle scenario. Temporary diagnostics showed only four
timer interrupts, a sleeper accepted at tick 1 with deadline 6, and eventual
resumption at tick 100 when a timeout ECALL finally accounted elapsed time.
At failure, MIE was enabled (`mstatus=0x10088`), the timer was running with a
pending event, and CLIC MIL remained at priority 3 (`mintstatus=0x7f000000`).
The selected task's last capture had been an ECALL (`mcause=0x0800000b`).

Returning from the timer with that older exception cause failed to unwind
the active interrupt priority on this silicon. Commit `83747ed` combines the
selected task's `mstatus` with the active trap's complete `mcause` before the
assembly epilogue. The current non-nested path follows the pinned IDF
interrupt epilogue's cause restoration. Integer-frame and 8-byte return-state
layouts remain unchanged. See [ADR 0007](../adr/0007-native-preemption-and-elapsed-time.md)
and [IDF v5.4.4 vectors.S](https://github.com/espressif/esp-idf/blob/v5.4.4/components/riscv/vectors.S).

After that correction, repeated boots exposed an IPC fixture lifetime race:
the service could exit immediately after sending its final response, before
the client popped it and notified the producer of released space. Diagnostic
failure code 141 identified that notification error; queue-full and both wait
paths had already been exercised. A copied item remains valid across a
notification failure, but this fixture deliberately requires every notice to
succeed.

Commit `715da60` therefore keeps the response producer alive until a separate
completion ACK. The client posts it only after all 64 values and their space
notices pass. The service then exits normally. Latched events handle both
ACK-before-wait and ACK-after-wait. This preserves the strict notification
checks and establishes endpoint lifetime for this bounded fixture; it does
not introduce a general channel-close interface. Temporary diagnostic code
was removed from the qualified image.

## Other hardware checks

All three boots also passed CPU0 integer and FP timer preemption, lifecycle,
latched events, CPU0-local channels with RV32 counter wrap, one-way owner
notifications, duplex IPI/WFI, and normal restoration probes for both IDF
hosts. CPU0 FP preemption performed 30 saves and 30 restores each boot, with
both register probes and the boundary-bank restoration check passing.

CPU0-local IPC delivered 64 ordered pairs, with one deliberate full rejection,
61–64 readable waits and 61–62 writable waits, correct checksum, empty final
queues, expected task exit codes 53/59, and two reaps. The final IDF timer
delivered 128 callbacks per boot in 128,085–128,086 us after native leases
were released.

The first boot exchanged 100,000 SMP mailbox messages in 24,226 us and copied
128 KiB on each of the four internal/PSRAM DMA paths. The display reported
720x1280 RGB565 scanout; each boot observed 60 vsyncs in 916,511–916,517 us,
about 65.465 Hz. This is panel scanout timing, not rendered game FPS. Touch
initialization completed eight polls each boot with zero observed points;
pressed coordinates and multi-touch were not qualified.

## Regression checks and boundary

The final committed implementation passed the full ESP-EMU core smoke as
well as the physical boots. Debug and ReleaseSafe each passed 51 host tests;
ZLint reported zero errors and warnings across 31 files. Formatting,
ShellCheck, RV32 architecture compilation, and both IDF target builds passed.
The C/Zig/Rust ABI probe also passed after the CLIC change; the later ACK
change only affects the native IPC fixture. The final image is 208 bytes
larger than `a9b67e0` and retains 60 percent free in its 1 MiB app partition.

IDF still owns boot, initial CPU1 launch, and resources outside the bounded
native windows. CPU1 FP switching, nested traps, permanent native ownership,
rights enforcement, migration, general cancellation, Flash/cache-off
coordination, long-duration stability, and game/audio-load behavior remain
separate work. No Quake FPS or security-isolation claim follows from this
functional qualification. The serial capture process exited and released
the port after the third completed boot.
