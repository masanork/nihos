# Normal touch controller host simulation, 2026-10-28

This change closes the gap between the pointer-only normal UI fixture and
its production touch reader. The native foreground service was moved verbatim
(apart from whitespace) into `input/touch_service.zig`. The native owner and
host fixture instantiate the same implementation. The native shim retains its
existing public entry points, polling interval, failure latch, queue and counters.

## Implemented scope

GT911, ST7121 and ST7123 modes execute production device identification,
`Touch.Device.sampleBatched`, 33,333-us poll gating, pointer rotation, stale
cancellation and queue overflow handling before the existing normal UI button.
The bus fixture validates addresses, registers and transfers up to 64 bytes.
It encodes synthetic reports, including sparse late slots, and injects failures
at status reads, first/second report reads, ACK writes, geometry and reset flags.

The Sitronix fixture consumes a complete register snapshot; GT911 consumes it
on the driver's successful ACK write. Neither establishes physical report or
IRQ persistence. A fixed virtual clock is used, so there is no transfer-duration
or latency measurement. The canvas spaces controller reports by at least one
virtual poll interval; raw HTTP/replay samples can test shorter intervals.
Normal direct-input mode and existing traces remain available. Controller
choice, slot count, sparse placement and failures are retained for replay.
Card traces and PIN privacy restrictions are unchanged.

## Results

| Check | Result |
| --- | --- |
| Python regression suite | 286 passed, including 36 simulator/HTTP cases |
| Card headless contracts | 14 / 14 |
| Normal UI/controller headless contracts | 15 / 15 |
| Zig Debug and ReleaseSafe | Passed |
| Static analysis and six audited RV32 links | Passed |
| JavaScript syntax | Passed |
| Native normal-display build/image audit | Passed |
| Native default connected build/image audit | Passed |
| Native read-enabled automatic-card build/image audit | Passed; 50,048-byte static heap |
| Physical I2C, touch, display or reader access | Not performed |

The macOS arm64 host source/compiler identity is
`877f52b7789275badd22d6f0fa288ab4d6b10fcfb1d0a024b1c9400a29a948ba`.
The [receipt](evidence/2026-10-28-touch-controller-host/source-witness.json)
and [normal report](evidence/2026-10-28-touch-controller-host/normal-report.json)
bind results to the host libraries and runtime sources. The regression log and
native layout audits are retained alongside them. A replayable
[controller fault trace](evidence/2026-10-28-touch-controller-host/controller-fault-trace.json)
and its final state are also retained.

Tests show that missing reports do not generate release, early polls preserve
pending reports, late reports cause cancellation, and neither partial burst
reads nor failed ACKs publish a successful sample. Hardware errors cancel an
armed button and stop subsequent bus transactions until reset, even after
fault injection is cleared. Controller queue overflow and failure traces replay
to identical counters and frame hashes. A subsequent tap works after reset.

The Sitronix ten-slot path requests two report reads (63 + 7 bytes) instead of
ten separate seven-byte reads. This is fixture transaction-count evidence,
not a physical speed measurement. Slot counts 1, 9 and 10, a contact only in
the last slot, and all ten contacts are covered.

## Base-image memory comparison

Baseline is main `add4e7e`; the candidate also includes the subsequent
linear-mask main change `d4de0ce`. Candidate and baseline were built with identical
options in separate worktrees. Both audited SRAM layouts are unchanged,
including primary static bytes, stacks, heap and service SRAM extents.

| Configuration | Baseline free static heap | Candidate free static heap |
| --- | --- | --- |
| Normal display, network disabled | 89,472 bytes | 89,472 bytes |
| Default connected normal base | 58,176 bytes | 58,176 bytes |

The first configuration sets `NIHOS_NATIVE_NETWORK=0`, `NIHOS_NATIVE_DISPLAY=2`,
`NIHOS_NATIVE_PSRAM_200=1`, `NIHOS_NATIVE_CONSOLE=1`,
`NIHOS_NATIVE_CONSOLE_LIVE=1`, and `NIHOS_NATIVE_KEYBOARD_I2C=1`.
The second uses `sh tools/build-native.sh device integer` with no feature
overrides. The [comparison](evidence/2026-10-28-touch-controller-host/memory-comparison.json)
retains each ELF hash. Host register buffers are not linked into either native
application. No network integration receipt or credentials are published here.

## Browser and physical limits

The browser widgets expose controller/slot selection, sparse reports and
failure injection; their HTTP paths and JavaScript syntax were checked. Native
Chrome access detected a user focus change, so interactive controller-widget
verification was interrupted and is not claimed. The dedicated in-app browser
host was unavailable. The prior normal-UI browser observations remain scoped
to the earlier candidate.

Real I2C electrical behavior, controller report persistence, panel latency,
optical flicker, and physical card interoperability remain separate gates.
No serial port was opened and no firmware was installed.

## Reproduce

```sh
python3 tools/card_sim/app.py --application normal --port 8713
# http://127.0.0.1:8713/?app=normal
python3 -m unittest discover -s tools -p '*test.py'
python3 tools/card_sim/app.py --headless build/card-sim/evidence
```

Choose a controller in the normal UI, then touch LOGS/SPLASH. Apply a failure
and touch again to observe input stop; reset to identify and resume the device.
See the [simulator guide](../card-ui-simulator.md) for the complete scope.
