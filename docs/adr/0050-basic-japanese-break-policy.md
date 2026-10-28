# 0050: Basic Japanese prohibition boundaries before placement

Status: accepted for host/native-emulator qualification, 2026-10-28.

Keep character policy separate from shaping and the existing 26.6 flow cursor.
`graphics.japanese_break` builds a caller-owned source-boundary map: one byte
per UTF-8 source byte plus the endpoint. Each entry distinguishes a scalar start
from a permitted break. UTF-8 continuation bytes cannot be glyph cluster starts.
Reject invalid UTF-8, CR/LF, wrong capacity and source/output alias before writes.
The caller splits hard paragraphs and keeps source/map storage valid during use.
The paragraph endpoints are forced boundaries; an opening mark at the end of
an input fragment, or closing mark at its start, is not silently deleted or fixed.

Use the principles in JLREQ [3.1.7](https://www.w3.org/TR/2020/NOTE-jlreq-20200811/#characters_not_starting_a_line)
and [3.1.8](https://www.w3.org/TR/2020/NOTE-jlreq-20200811/#characters_not_ending_a_line)
for an explicit **basic subset**, not a JIS X 4051, JLREQ or UAX14 conformance
claim. The `noEnd` / `noStart` switches are the authoritative supported set:

- No break after the listed ASCII, curly, fullwidth, halfwidth and Japanese
  opening brackets/quotes.
- No break before their listed closing forms, ASCII/Japanese punctuation,
  middle dots, iteration/voicing marks, prolonged sound marks, listed small
  hiragana/katakana, Katakana Phonetic Extensions and small halfwidth kana.
- Other scalar boundaries are candidates, still constrained by shaping clusters.
  Ambiguous ASCII quotes, hyphen classes, inseparable dashes/ellipses, western
  word boundaries, whitespace, combining/grapheme segmentation and newer Unicode
  additions are not inferred. This table is a named finite policy to extend with
  acceptance cases, not a complete character-class database.

The span adapter starts at a shaping-cluster head, walks whole monotone LTR/TTB
clusters and joins across prohibited boundaries in the same run. It never splits
a shaping cluster, including multiple glyphs with one cluster ID. It reads this
run's UTF-8 byte offsets and refuses out-of-range/non-scalar offsets. Only then
pass the summed span advance to `Flow.place`. A long connected span fails with
`SpanTooWide` instead of breaking a prohibition or hanging ink outside the box;
a full box similarly fails without consuming the cursor. No backtracking,
justification, punctuation compression or hanging punctuation is implemented.
Inline limits still bound advances rather than ink.

Native qualification retains the existing unwrapped and cluster-only digest
checks, then adds a third pass on the **same** guarded canvas before raster
retirement. A horizontal 80 px line would otherwise start with `、`. A vertical
64 px column continues from a 32 px occupied prefix; without policy its last
column would start with `。`. Prohibition grouping moves their preceding base
with the punctuation. The half-size ruby run also joins `きょ`, but ruby remains
independent of its body. Require three frames, 30 spans from 33 shaping clusters,
three joined boundaries, ten occupied lines/columns, five transitions and no
clipped glyphs. Native digests must match independent batch Python placement
and per-source-pixel composition. Same-geometry **host** controls expose two
line/column-start violations when the policy is disabled. Host tests separately
expose and repair an opening bracket stranded at a line end, and cover a
multi-glyph cluster, oversized chains and invalid source offsets.

For this finite native fixture, source maps are computed at build time from
the canonical immutable body/ruby inputs. Runtime maps for arbitrary caller
text are host-tested but not exercised on the native task/IO path. Put those
immutable maps and descriptors in the existing loader-mapped display-data span;
no executable kernel, allocator or interrupt helper moves out of SRAM. Use
numeric case IDs in the map's type name: embedding Japanese text there made
ELF symbol names non-ASCII and was rejected by the existing image auditor.
Preserve that failed candidate; do not weaken symbol parsing to admit it.

Retain the 48 KiB primary heap floor and compiler runtime safety. Initial links
exceeded it. Share all three placement passes and the checked drawing/cluster/
cursor call paths, and keep the complete diagnostic archive in bootstrap-owned
PSRAM: 2,496 B glyphs plus 240 B snapshots/hashes = **2,736 B**, still charged
**4,096 B**. Fill snapshots in request order and expose only their initialized
prefix; after final logging free the archive and expose an empty slice. Canvas
and raster charges remain 64 KiB and 32 KiB, respectively; there is no extra
canvas allocation. Existing two-root limits and fixed font-stack/library SRAM
reservations are unchanged. The device profile retains exactly **49,152 B**
primary heap; further features need a fresh placement/budget decision.

Body/ruby association, automatic ruby placement across lines, page layout,
vertical-in-horizontal settings, bidi/contextual reshaping, native font storage,
physical cache/display behavior and service restart remain separate gates.
