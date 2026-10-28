# 0053: Runtime-owned text and layout context bound to the font reply

Status: accepted for bounded host/native-emulator qualification, 2026-10-28.

Replace the native consumer's build-time source maps/annotations with one owned
runtime context. It copies bounded Render body/ruby bytes and at most eight
annotations, validates UTF-8/scalar ranges, creates basic-prohibition maps at
runtime and seals source/metadata/map contents with a diagnostic checksum.
Require a nonzero request revision; the font worker independently hashes the
copied Render actually received and echoes that hash in text reply `hashes[1]`
(matrix requests retain all sixteen hash slots). The IPC packet does not grow. C++ Job,
Render and Output ABIs are unchanged. This is content/revision qualification,
not cryptographic authentication or concurrent-writer synchronization.

Prepare into private bounded scratch and assign the complete output only on
success; a failed `initInto` leaves the previous value untouched. Caller storage can
be poisoned after queue publication. Keep the active context in the bootstrap's
existing PSRAM diagnostic archive until the sole outstanding request/raster is
retired; never retain slices into a caller stack or overwrite a borrowed context.
Source validation rejects stale revision, changed bytes/annotations/maps and
wrong reply hash before allocating or drawing a new canvas. Shaping-cluster
alignment is still validated by the ruby planner after glyphs exist.

Eight explicitly whitelisted RX Flash functions contain finite input preparation,
source verification, draw/source hashing, completed-record reporting and the
existing paint/draw path. SRAM gates check CPU0 bootstrap/MIE before preparation,
verification, drawing and reporting. Worker source hashing follows the existing
SRAM font-owner/MIE gate. Queue operations, allocation, timer/trap handling,
bootstrap canvas guards, task reaping and archive retirement stay in SRAM.
The report function receives completed records only; it cannot submit jobs or
retire storage. UTF-8 decoding expands inside Flash preparation; glyph output
validation is outlined once to avoid duplicate SRAM code. Runtime bounds and
overflow checks remain enabled (`-O safe`); the 48 KiB heap floor, 16 KiB frontend
Flash limit, two loader mappings, stack reservations and root quotas are unchanged.
No native filesystem or cache-off rendering claim follows from runtime text.

For proof, edit the first mutable caller body from `日本語の描画` to `新日本語`
and shift its `日本語` ruby interval from bytes 0..9 to 3..12 before submission.
Native Options retain the original literals; the worker must shape the edited
copy and runtime layout must consume matching maps/annotations. Compare actual
new glyphs/A8/all four compositions with a separate sanitized host execution
using independently specified post-edit cases. Retain the unchanged four-cycle
matrix and the two failure jobs. Horizontal first-case ruby geometry uses a
40 px line step and y=24 so the newly prepended character and moved group fit
without clipping. Poison both caller source and annotation storage.
Reject invalid prepare input without replacing the active context, then exercise
stale-revision/content/map/annotation/reply-hash controls on successful replies.

External font IO needs persistent native storage ownership, waits and source
revision/removal handling; the existing boot-only SD path does not provide that.
Production document parsing, application routing, scanout, cache-off exclusion,
service restart and physical qualification remain separate gates.

Measured candidate: emulator/device primary static SRAM is 114,432/114,688 B;
primary heap is 49,408/49,152 B. The device candidate has no headroom above the
unchanged 48 KiB floor. The frontend is 16,040 B, 344 B below its unchanged
16 KiB ceiling. The context is 556 B and archive is 3,336 B charged at the same
4,096 B as before. The font stack/library reservation remains 64 KiB resident;
these qualification numbers do not establish a demand-loaded production service.

All five source copies/echoes, ten maps, five invalid prepares and fifteen
consumer mismatch controls pass. The 124 real draws and six timer captures of
Flash renderer PCs precede complete PSRAM recovery. The exact captured candidate
and source/artifact hashes are recorded in
[`2026-10-28-native-runtime-text.json`](../measurements/2026-10-28-native-runtime-text.json).
