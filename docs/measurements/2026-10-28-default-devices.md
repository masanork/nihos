# Default on-demand native devices: combined physical checkpoint

2026-10-28 JST, integrated with main `5910238` and based on source commit
`15b134742984332978eda5e02b84915263b84ae6`. See [ADR 0052](../adr/0052-default-on-demand-device-drivers.md).

The exact candidate includes speaker, microphone and UART1/RS485 alongside the
existing C6/display/board services. One warm-reset capture ran for
88.023 seconds under one exclusive serial descriptor.
The [machine report](evidence/2026-10-28-default-devices/report.json),
[raw serial log](evidence/2026-10-28-default-devices/serial.log),
[command schedule](evidence/2026-10-28-default-devices/commands.json),
[loader/image audit](evidence/2026-10-28-default-devices/image-audit.json) and
[identity/restoration receipt](evidence/2026-10-28-default-devices/qualification.json)
are retained. This is controller evidence, with no external RS485 or audible
output claim.

| Check | Observed |
| --- | --- |
| Startup idle | Availability bitmap 7; no requests, owner, pinned storage or DMA workspace |
| Microphone → overlapping speaker | Capture accepted, speaker rejected |
| Speaker → overlapping microphone | Playback accepted, microphone rejected |
| Microphone repeated after speaker | Second capture accepted and completed |
| Speaker completion | 8192 frames; DMA EOF, FIFO drain, amp/codec off, stopped/returned |
| Both microphone completions | 512 four-slot samples each; stopped/returned, PCM erased/writeback |
| UART internal exchange repeated | Both 64 TX/64 RX, exact reply, no line errors, DIR low, stopped |
| Shared workspace | 1536 bytes after first audio request; same descriptor area reused, final owner/pinned 0 |
| Static primary heap | 50432 B; disabled profile 55808 B on the same main |
| SRAM cost / foreground Flash code | 5376 B / 9414 B |
| UI/harts | First counters {'frames': 32, 'ticks0': 15, 'ticks1': 15}; final counters {'frames': 5135, 'ticks0': 8523, 'ticks1': 8523} |
| Native failure / restoration | No failure; original app verified restored; first 64 KiB unchanged |

The physical image SHA-256 is `09fe70863df2abf002fc7d0c04931a801249d41fc16354f58a822552088cd2b8`.
The freeze records exact build-source hashes and source archive independently
of later evidence-only commits. Credentials were not configured; BLE discovery
and C6 service ran, but associated Wi-Fi traffic is not proved by this capture.
RTC presence was observed with invalid calendar data; NTP synchronization is a
subsequent change, not a claim of this checkpoint.

An earlier attempt was refused by the serial lock when another scene capture
acquired the port. It wrote no candidate bytes. The successful attempt verified
the retained scene loader bytes before replacing only the factory app at
0x10000, verified the exact app immediately before/after capture, then restored
the prior full 1 MiB app and rechecked the first 64 KiB. Private Flash/NVS backups
and raw firmware remain outside the repository.

External RS485, audio quality, optical display confirmation, cold power-cycle,
long-duration operation and current consumption remain unqualified.
