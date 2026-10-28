# 0045: Bounded, owned UTF-8 inputs for font requests

Status: accepted for local host/native-emulator qualification, 2026-10-28.

Extend the existing single-dispatcher request/reply boundary with `render_text`.
Each request owns up to 128 UTF-8 bytes of body text and 64 bytes of optional
ruby text. Explicit lengths exclude unused array bytes. Empty body, malformed
UTF-8, out-of-range lengths and unsupported settings fail validation before
the sequencing state consumes an ID. The worker independently validates the
copied payload; this finite native harness supplies only validated requests.

Select Gothic/Mincho, 12/16/24/32 body pixels, horizontal/vertical direction
and default/forced-auto/no hinting. These are instance settings, not shared
mutable face state. Script/language remain Han/ja; bidi and script
itemization are outside this boundary. Open only the selected face for a text request, render
body and optional half-size ruby runs, then close all request-owned memory.
This does not implement line wrapping, ruby placement or vertical paragraph
layout. The output remains a glyph/advance/raster digest, not an application
glyph buffer or framebuffer interface.

Store payloads inline in the existing bounded SPSC request queue. Its release
publication transfers a complete copy, and the worker copies that value into
a private C-call descriptor on its own stack. No client pointer or callback
crosses the queue. The descriptor's pointer is private to the synchronous
Zig/C++ bridge and cannot outlive that render operation. Keep font inputs
immutable and service-owned.

The native producer deliberately overwrites its source arrays and pixel size
after queue publication and before notifying the sleeping worker. All four
text results must still equal independently executed sanitized-host results.
Use one canonical input file to generate both native options and host inputs.

A missing glyph returns `render_failed`, zero completed runs and no published
digest. Close partial face/cache state before replying; subsequent valid
requests must still succeed on the same task. This qualifies one missing-glyph
failure, not all library OOM/cancellation/recovery paths. Malformed request
validation has host regressions; native rejection/reply routing for untrusted
applications is not part of this fixture.

Retain four original 16-case matrices as a regression baseline, then issue four
text requests and one ordered stop. Preserve blocking waits, the independent
terminal acknowledgment and task-ledger retirement from ADR 0044. Record
fixed queue/stack costs separately from demand PSRAM; bounded input capacity
is not a worst-case font or stack proof.

Application routing, glyph-buffer ownership, cancellation, native SD/VFS
font sources, service restart and physical Tab5 remain separate gates.
