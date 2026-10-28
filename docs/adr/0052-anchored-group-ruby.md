# 0052: Anchored, bounded group ruby before line placement

Status: accepted for host/native-emulator qualification, 2026-10-28.

Annotations belong to document/layout metadata, not the font worker. Keep the
existing copied body/ruby shaping request and glyph/raster ABI unchanged. An
annotation specifies sorted, disjoint, nonempty UTF-8 byte ranges in the body
and concatenated ruby source. Ruby ranges are contiguous and cover its complete
run. Both endpoints must be source scalar and whole shaping-cluster boundaries.
Refuse overlap, reordered ranges, uncovered ruby, out-of-range/mid-cluster
endpoints and unsupported glyph directions before publishing a plan.

Add an allocation-free bounded planner returning logical 26.6 glyph positions
and the resulting flow by value. Body and ruby glyph runs must be contiguous
monotone LTR/TTB streams. Each annotation makes an indivisible unit with advance
`max(body_advance, ruby_advance)`; center the shorter sequence, assigning an odd
26.6 remainder to the trailing side. No neighbor overhang, spacing distribution
or glyph rescaling is performed. Callers choose the block separation/line step;
ink clipping remains the surface's responsibility. Positive block direction is
down for horizontal lines and left for vertical columns, so ruby uses a negative
block offset above/to the right. Keep whole clusters within each sequence.

Use the group-ruby principle from JLREQ
[3.3.6](https://www.w3.org/TR/2020/NOTE-jlreq-20200811/#positioning_of_groupruby_with_respect_to_base_characters):
base and ruby form one object without an internal line break. The uniform
centering/reserved-width policy here is a deliberately bounded policy, not full
JIS/JLREQ ruby distribution, jukugo-ruby, neighbor overhang or line-edge
adjustment. Multiple explicit annotations can represent separately breakable
units; a long indivisible unit fails instead of being silently split.

Apply basic Japanese prohibitions between body units, including after a ruby
unit. Join across a prohibited boundary before calling the existing flow cursor.
A failed plan returns no partial positions or updated flow; caller state is
unchanged. Capacity is caller-selected at compile time, bounded to 256 glyphs;
the native fixture remains 16 glyphs. Report returned-plan and scratch-unit
storage separately from measured stack usage; reserve no new stack or heap.

Native qualification adds a fourth pass using the existing canvas/A8 lease.
Canonical annotation metadata binds `日本語` to `にほんご` and `東京` to
`とうきょう`. Continuation cursors force both annotated groups to the next
line/column. The latter ruby is wider than its parent and reserves that width.
A third no-ruby request checks compatibility with the basic prohibition plan.
Compare exact frame digests and logical associations with an independent batch
reference, plus fixed-origin controls and host invalid/multiple-annotation cases.
Keep prior three-pass digests, task-only Flash placement/preemption, the 48 KiB
primary heap floor, stack/canvas guards and complete heap recovery.

Dynamic native source/annotation construction and IO remain separate gates;
this native fixture uses canonical source-bound metadata. Application routing,
production ruby typography, scanout and physical qualification remain pending.

Final observations: native returns three fourth-pass frames, two moved ruby
units, one wider ruby, 21 body units, two prohibition joins and nine cursor
lines/columns including preoccupied starts; all ink fits the viewport. Plan(16)
occupies 172 B and its 16-unit scratch array 320 B on RV32; these are object
sizes, not a measured maximum stack call chain. Larger capacities need a separate
stack/workspace budget. Existing bootstrap/IRQ guards pass after each paint.

All three new native digests match the independent reference. Fixed-origin
controls differ on both annotated frames, and the no-ruby frame exactly matches
the preceding prohibition-only output. Prior matrix, A8 and three legacy
composition digests remain unchanged. Rendering remains within the existing
two-function RX Flash span (now 6,860 B) and is preempted/resumed successfully.
The device profile retains 50,944 B of primary heap, above the unchanged 48 KiB
floor. There is no new heap allocation, stack reservation or quota. The diagnostic
archive grows by 20 B to 2,756 B, still charged 4 KiB, and all memory is reclaimed.
