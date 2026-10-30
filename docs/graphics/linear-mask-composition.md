# Opt-in linear-light mask composition

`Surface.blitLinear` draws a borrowed A8 coverage mask to an RGB565 surface
using 16-bit linear-light lookup tables generated from the sRGB transfer curve.
The existing `blit` retains encoded-channel interpolation; current native UI
callers are unchanged. Neither API allocates or owns the surface. Both apply
the same geometry, clipping, stride and alias validation before writing.

RGB565 channels are decoded under the sRGB assumption, linearly interpolated by
coverage, then rounded to the closest encoded RGB565 value. The 16-bit tables
can differ by one channel level from a floating-point sRGB calculation at a
rounding boundary. An actual panel may have different response characteristics;
this is not calibration or a claim of optimal visual weight. This API does not
implement per-subpixel RGB coverage, dithering or a font rasterizer.

Tests cover endpoints, clipping and guards, every identical foreground/background
RGB565 value, and an independent floating-point reference for all 5-bit and
6-bit channel pairs at six intermediate coverages. Integrating a runtime font
renderer, selecting a default, and measuring performance and appearance on a
physical panel are separate work.
