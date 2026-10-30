# 0046: Owned, bounded glyph metadata in font replies

Status: accepted for host/native-emulator qualification, 2026-10-28.

Extend `render_text` replies with an inline, pointer-free output packet: an
outcome, a count and at most 16 glyphs across the body and ruby runs. Each
glyph contains ID, UTF-8 byte cluster, run (body 0/ruby 1), ppem, signed x/y
advances and offsets, signed bitmap bearings, and bitmap width/height. This
is 48 bytes per glyph and 776 bytes per packet in both Zig and C++.

Advances/offsets use signed 26.6 pixel units in font coordinates, with y up.
Bearings and dimensions are pixel units; `top` is the bearing above the
baseline. Clusters index bytes within the corresponding input run, not Unicode
character indexes or a concatenation of body and ruby. Runs have independent
origins. The caller must position them and transform coordinates for display.
No paragraph wrapping, ruby placement, bidi or script itemization is added.

Compute metadata while FreeType/HarfBuzz objects are live, then copy complete
results into the existing reply ring after closing the face/cache. No bitmap,
face, font or client pointer crosses the queue. The dispatcher copies replies
into its own snapshots. Poison the worker's reusable source packet after
publication; compare all retained snapshots after subsequent work and final
task retirement. Source-packet contents may be reused after publication; the
consumer's copy is independent of the FreeType bitmap's lifetime.

Keep unused slots zero. Missing glyphs return `render_failed`; exceeding 16
entries returns `output_full`. Both publish zero completed runs, digest, count
and glyph storage. A 17-character request must hit capacity after partial
work and still expose no partial metadata. Later requests must succeed.
Validate packet bounds/status before slicing or retaining data, and reject
failed packets with nonzero entries.

Retain the original 64 matrix cases. The five text jobs cover success,
missing glyph, capacity exhaustion, then two successful requests. Require
ten request waits and replies including stop, terminal acknowledgment, copied
input/output witnesses and complete task-ledger recovery. Compare all 33
successful glyph records with independently executed sanitized-host output.

The two queues now reserve 3,072 B, including inline metadata. Five retained
packets are qualification snapshots, not a production per-client cache.
Native primary static grows by 7,040 B (emulator) or 6,912 B (device build).
The reusable C++ packet adds 776 populated bytes inside the existing 32 KiB
library region; that fixed reservation and the 32 KiB task stack do not grow.
Report these fixed costs separately from demand PSRAM.

Actual bitmap delivery needs its own bounded ownership/retirement contract.
Application routing, larger runs, cancellation, service restart, native font
storage and physical display/Tab5 qualification remain separate gates.
