# 0049: Bounded flow of indivisible shaping clusters

Status: accepted for host/native-emulator qualification, 2026-10-28.

Add `graphics.line_layout` as an allocation-free placement primitive, independent
of font libraries, pixels, queues and storage. A caller supplies a positive
inline limit, positive block step and line/column capacity, in signed 26.6 units.
Each nonnegative span either fits, starts the next line/column, or returns a
typed error. An oversized span or exhausted block leaves the flow unchanged so
the caller can try another box. Exact fits and zero advances are valid. This
primitive stores only the current cursor; it does not retain the paragraph.

A separate adapter groups consecutive glyphs with equal run and shaping-cluster
IDs. Sum the advances before placing the whole group; never split that group
across a line. Support monotone LTR and TTB streams with nonnegative inline
advances and zero cross-axis advances. Reject descending clusters within a run,
unsupported advances and numeric overflow. Signed bitmap offsets and bearings
still apply after placement. Caller-defined spans may later represent larger
legal break units without changing the flow cursor.

This is greedy cluster flow, not Unicode line breaking or Japanese typography.
A shaping cluster is not necessarily a grapheme, word, legal break opportunity
or ruby base. Kinsoku, punctuation adjustment, word boundaries, explicit line
breaks, bidi, contextual reshaping at line boundaries, paragraph/page planning
and caret mapping need their own policy and acceptance cases. Inline advance
bounds do not guarantee that glyph ink lies within the box; clipping remains a
surface responsibility. Body and ruby runs are still independent: wrapping the
body does not associate, distribute or move its ruby. Do not advertise complete
ruby layout or a production reader/editor from this fixture.

For native qualification, reuse each existing 192x96 guarded RGB565 canvas for
a second pass before releasing the borrowed A8 raster. Wrap horizontal body
runs at 96 px (two lines, 32 px step); wrap the vertical body at 64 px (three
columns, 40 px step, right to left). The independent ruby run has one 96 px
line/column. Require three wrapped frames, 33 clusters, nine occupied
lines/columns, three wrapped runs and four transitions without clipped glyphs.
Compare complete padded RGB565 digests to an independent batch Python reference
using captured host masks. Preserve the earlier unwrapped/clipped digest checks.
Host synthetic cases additionally cover a cluster containing multiple glyphs;
the pinned native texts themselves contain one glyph per cluster.

Keep the 48 KiB primary heap floor and compiler safety checks. Move only the
qualification archive of three successful glyph arrays (2,496 B) from static
SRAM to bootstrap-owned PSRAM, allocated on preparation and charged 4 KiB by
the existing buddy allocator. It remains available after the font task exits,
then is explicitly freed after logging, with the public snapshot accessor empty
thereafter. This is diagnostic storage, separate from font-worker ownership.
The bootstrap ledger holds at most archive plus canvas; worker ownership remains
font backing plus raster. No root quota or stack reservation is enlarged.

Report the archive's allocation and final free separately: while it is live,
font-task lifecycle free heap is 16,018,752 B; after archive retirement the
original 16,022,848 B returns. The combined primary static span grows by only
256 B relative to surface composition; device-profile primary heap is 50,048 B.
The existing 64 KiB canvas charge is reused, not doubled. Font/raster peaks
remain separately measured, not a sampled combined-memory peak. Fixed font
stack/library SRAM remains reserved even when there are no open clients.
