# 0047: Lazy, borrowed A8 raster leases

Status: accepted for host/native-emulator qualification, 2026-10-28.

Allocate a logical 16 KiB raster buffer from the font task's existing PSRAM
heap only for a text job. Its authentic allocation remains in the task ledger,
beside the font extent group. Actual buddy charge is 32 KiB. Normalize each
FreeType grayscale bitmap into tightly packed, top-to-bottom A8 rows before
the next glyph overwrites it. Append byte offsets to glyph metadata and publish
only the completely initialized prefix; failures discard the allocation before
replying. No bitmap bytes are stored in the reply ring.

The reply carries a nonzero generation token and byte count in its metadata.
A guarded reader validates current task identity, phase, token and exact length
before returning a const slice. The producer cannot reuse the allocation while
published. The sole consumer must finish all reads, retire its lease, discard
every borrowed view, and send a release control message before another normal
job or stop. The worker reclaims and acknowledges release. Lookup after retire,
after reclaim, or using an old token after allocation reuse must fail. Only
the producer can free the actual allocation. Tokens do not revoke arbitrary
retained raw pointers; respecting the borrow contract is mandatory.

Use one outstanding raster in this fixture. Release control messages use the
same bounded request channel and do not consume normal work IDs. Preserve the
existing independent stop acknowledgment. These are serialized same-CPU
endpoints; multiple clients, forced termination, cancellation, restart epochs
and a multi-slot raster pool require separate lifetime protocols.

Hold each of three successful rasters for two real ticks after face/cache
close. Re-read its digest, and reconstruct the original glyph/advance/pixel
digest from copied metadata and the borrowed bytes. Compare with the original
FreeType digest and an independent sanitized-host execution. Reject foreign
free attempts and stale/retired tokens. Five text allocations must yield two
immediate discards and three acknowledged releases, leaving zero raster charge
before service EXIT and full heap recovery after task-ledger retirement.

The A8 results contain 3,441, 4,558 and 1,774 bytes (9,773 total). Queue storage
is 3,200 B; no pixel array is in the queue. Primary static increases by 4,736 B
(emulator) or 4,864 B (device build), including the driver and lease checks.
The device profile retains 52,224 B of primary SRAM heap, above its 48 KiB
floor. Existing fixed stack/library reservations do not grow. Font-span peak
backing and raster charge are separate measurements; their simultaneous total
peak is not established by the individual high-water values.

The host atlas is a per-glyph diagnostic, not paragraph layout or native LCD
presentation. Native display/cache/DMA behavior, SD/VFS font input and physical
Tab5 remain unqualified.
