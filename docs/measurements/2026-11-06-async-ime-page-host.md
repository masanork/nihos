# Async page handoff prototype

The experimental page coordinator separates request, completion and copy-out.
It admits one page request, tags it with a generation and serial, and copies
bytes only after an exact, trusted completion. A cancelled request remains in a
single draining state until completion; detach and reuse are refused while it
is pending. Stale, duplicate, malformed, and old-generation completions cannot
publish a page. A failed or short read fences the current attachment.

The host integration reads the NFST header through a recovered, pinned
5,129,285-byte checkpoint-store object. A second request is cancelled while
pending; the test verifies detach is refused until the simulated completion.
Unit tests cover copied ownership, duplicate/stale replies, short reads,
re-attachment and cancellation. The caller supplies the pin identity; the
coordinator does not verify or own the actual pin. Completion must be
serialized, authenticated, and called only after the producer has ceased
using its buffer.

This is a page transport boundary, not yet an asynchronous NFST parser or IME
conversion: the existing reader and conversion still perform synchronous reads.
No task, native SD RPC, DMA, interrupt, device timing, or physical cancellation
was exercised. Native integration must connect the parser continuation and
existing storage lifetime/drain rules before claiming non-blocking operation.
