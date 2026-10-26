# Bounded native portrait decoder

OpenJPEG 2.5.4 comes from the official `v2.5.4` archive, SHA256
`a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a`.
`tools/bootstrap-openjpeg.sh` verifies the archive before extraction.
The original BSD-2-Clause notice is in `OPENJPEG-LICENSE.txt`.
No source from the user's civ reference repository is copied here; its AP
sequence and tag definitions were consulted for interoperability.

The source library is unmodified. `noio.h`, configuration headers and
`decoder.c` supply a bounded memory-only build, private allocator, no threads,
no diagnostics and deterministic math/sort helpers. Link garbage collection
removes encoder APIs; the image auditor rejects any surviving encoder or I/O
entry point. HTJ2K decoding is explicitly disabled by `ht_stub.c`.

The adapter accepts at most 32768 encoded bytes, dimensions up to 512x640,
one or three components, and precision up to 8 bits. It uses one level of
resolution reduction and aspect-fits into 96x128 RGB565. RGB, grayscale and
SYCC colour conversion are supported. SYCC coefficients follow upstream
`src/bin/common/color.c`. Unsupported inputs fail without publishing pixels.
Allocation exhaustion fails within the supplied arena; an individual image
may exceed that quota even if its dimensions fit the profile.

All committed images are synthetic colour gradients. Fixture provenance and
checksums are in `fixtures/provenance.json`; expected pixels were generated
with stock OpenJPEG 2.5.4 and RGB565 conversion. The native fixture reference
checksum detects target/soft-float discrepancies before any credential is
offered. `test.c` checks exact pixels, output/arena guards, truncated inputs
and quota exhaustion. Run `sh tools/check-photo-codec.sh` with ASan/UBSan.
It is a narrow regression suite, not a general decoder security proof.

Target code is opt-in DISPLAY=10. CPU0 switches to its quiescent 12 KiB worker
stack for decoding, preserves interrupt stack isolation, checks a bottom
guard, reports high-water usage and erases it afterwards. Static C-frame
metadata is audited separately and does not claim a whole-call-graph bound.
Actual card images/attributes/credentials never leave the device.
