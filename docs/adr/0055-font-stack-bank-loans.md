# 0055: One-shot font stack bank loans, separate from library reinitialization

Status: accepted for bounded host/native-emulator qualification, 2026-10-28.

Treat the fixed 64 KiB font reservation as two different resources. The 32 KiB
stack bank has no persistent library objects. Its lifetime is tied to scheduler
frames: do not lend while a font task can execute, wait or retain a saved frame.
The other 32 KiB contains loader-initialized writable data, zeroed BSS, the
allocator controller and HarfBuzz globals. Client close does not reset that
state; post-retirement pointers can refer to freed backing. Lending that region
before a later font startup needs an identity-bound pristine initialization image
and a supported library lifecycle. It is not implemented by clearing BSS alone.

Start with a serialized safety gate for the single fixed stack bank. A claim has
an instance-bound, nonwrapping generation and a role (scratch or font). Busy,
stale, copied-metadata, wrong-role and exhaustion checks precede any bank write.
The one font lifetime can return its claim only after independently established
terminal acknowledgement, worker EXIT, task-resource cleanup and scheduler reap.
All four facts are required. Closing the font claim does not allow a second font
startup: the library lifetime remains one-shot. Scratch claims before the first
font admission and after retirement are allowed. The gate is not an allocator,
PMP capability, lock, page registration or kernel free-heap accounting.

The existing broker contract was reviewed at commit b69b7c3 (memory_broker.zig,
page_pool.zig and ADR 0049). No source was copied. Future integration should give
the whole bank to one broker and pin its parent through the live scheduler frame
lifetime; this experiment does not register the range with a second allocator or
bypass group quotas/floors. Platform serialization and quiescence proofs remain
the caller's responsibility. Failed one-shot startup halts the qualification;
startup rollback/retry is not a production service contract in this stage.

For executable acceptance, a separate RGB565 consumer borrows the same bank
before font preparation, clears all 32 KiB, then uses the shared Surface fill/A8
blit API for a 128x96 image. A 64-byte prefix and the remaining suffix are guards.
Its lease is returned before the bank is filled with the font stack pattern and
initialized as a real task stack. While font-owned, a scratch claim and premature
return are rejected. After successful result collection and actual worker reap,
the kernel returns the font lease using metadata only under its IRQ mask. Only
later, with bootstrap/MIE restored, the RGB565 consumer borrows and overwrites the
bank again; the old scratch ticket must fail. Both pixel hashes must match a
separately generated scalar host reference. Bootstrap/IRQ guards pass after
both loans. The original font stack guard/watermark evidence is collected before
its retired bytes are repurposed; it is not read as a live stack afterwards.

Ownership, scheduler hooks, guards and metadata stay in SRAM. Pure borrowed-bank
painting joins the exact private RX Flash whitelist behind an SRAM context gate.
Outline the existing repeated runtime source check into one private Flash helper
to keep the unchanged 16 KiB frontend cap. No IRQ performs paint, clear or loan
payload work. The original 48 KiB primary heap floor, stack-bank bounds, two
loader mappings, glyph/packet capacities and PSRAM quotas remain enforced.

All prior matrix/glyph/A8/four-frame, source-identity, queue and final PSRAM
recovery checks remain required. Device profile evidence is compile/loader audit;
physical Tab5 cache, interrupts and bank reuse still require separate execution.
The 32 KiB bank remains address-reserved and directly usable by this lease adapter
while inactive; it is not 32 KiB added to the primary heap. The library's other
32 KiB stays exclusive. General broker allocation, arbitrary application access,
restartable fonts, native SD font IO and scanout remain separate integration.


The exact candidate passes 255 Zig tests, 193 Python tests, static analysis,
six default native ELF links, both graphics profile audits and native emulator
execution. Both scratch hashes are 1,907,333,006. The 32 KiB bank remains at
0x4ff6e000..0x4ff76000; two scratch loans, two guard checks, three busy refusals,
one stale ticket refusal, one premature return refusal and one post-reap font
return are captured. All prior font/source/queue/frame results remain identical.

Device/emulator primary heap is 49,152/49,408 B; primary static SRAM is
114,688/114,432 B. Control/probe overhead consumes the preceding stage's device
1,152 B margin. No heap floor or stack reservation is reduced. Frontend Flash
is 14,890 B (1,494 B below the 16 KiB cap), including the outlined shared source
check and borrowed-bank paint. Primary heap capacities are separate from the
32 KiB whole-bank scratch availability. PSRAM charges and final recovery remain
unchanged. The final source/image/capture receipt is
[`2026-10-28-native-stack-loan.json`](../measurements/2026-10-28-native-stack-loan.json).
