# 0048: Shared, borrowed RGB565 surfaces and A8 composition

Status: accepted for host/native-emulator qualification, 2026-10-28.

Add an allocation-free `graphics.surface` primitive, independent of fonts,
queues, filesystems and display drivers. A caller supplies mutable RGB565LE
bytes, dimensions and byte stride. An A8 mask supplies immutable bytes,
dimensions and byte stride; placement uses signed pixel coordinates. Validate
geometry, arithmetic and source/destination non-aliasing before writing.
Clip against the destination, including negative positions and wholly outside
masks. Keep row padding untouched. The caller owns buffer lifetime and exclusive
write access; this primitive neither synchronizes writers nor presents frames.

Blend the 5/6/5 destination channels with an opaque RGB565 ink and 8-bit coverage,
rounding each channel with `(ink*a + background*(255-a) + 127)/255`. Transparent
coverage preserves the destination; opaque coverage replaces it exactly. This
defines quantized RGB565 blending, not a color-management or gamma policy.

The qualification driver consumes copied glyph metrics and a guarded raster
view. Use explicit independent body/ruby origins, signed 26.6 floor conversion,
bitmap bearings, and y-up to y-down conversion. These finite placements are
not paragraph layout or automatic ruby association. Compose before retiring
the raster lease; no borrowed mask pointer survives release.

For each successful request, allocate an offscreen 192x96 surface in the
consumer task's existing PSRAM ledger, with 400-byte stride, 32-byte guards
at both ends and sentinel row padding. Logical allocation is 38,464 B including
guards; actual buddy charge is 64 KiB. Compare the resulting padded surface
digest with an independent Python implementation that checks every source
pixel rather than using the native clipped-span algorithm. Exercise negative
placement, five clipped glyphs, truncated masks and alias rejection. After
guard checks and digest capture, free the offscreen surface, then retire/release
the mask through the existing protocol. A real scanout buffer will need its
own presentation lifetime.

Do not reduce the 48 KiB primary heap floor to fit the renderer. The first link
exceeded it. Compact only qualification archives: store successful glyph arrays
once, retain small summaries for failed replies, and validate empty failed
packets before discarding their storage. IPC replies and ownership are unchanged.
Native primary static grows by 1,920 B net; the device profile retains 50,304 B
of primary heap. Keep compiler safety checks enabled.

Require three frames, 33 blits, five clipped glyphs, intact padding/guards,
six invalid-operation rejections, zero canvas charge after composition and
complete final heap recovery. Host PNGs visualize reference output only;
native hashes match them, but LCD/cache/DMA, physical Tab5, multiple application
writers, wrapping, ruby layout and native font storage remain separate gates.
