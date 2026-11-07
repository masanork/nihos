# Resumable conversion with page requests

This host-only prototype connects `SlicedConversion` to the resumable NFST
lookup. If a phrase or candidate population needs a lookup, the conversion
returns `waiting`. The caller advances the lookup and supplies page responses,
then retries the interrupted unit. Previously completed lookup results are
copied into bounded caches, and partial candidate-pool writes are rolled back
before retry. The engine publishes no segments until conversion completes.

The fixed cache holds up to 128 existence answers and eight full candidate lists;
exhaustion returns `Capacity` and discards the conversion, rather than silently
changing output or retrying forever. The adapter occupies 27,848 bytes on the
host, excluding the 4 KiB page coordinator, conversion engine and cursor. A
caller must serialize the job, keep the same object pinned and cancel both the
conversion and the lookup; an outstanding page must complete and drain before
detaching the coordinator.

On a recovered file-backed store containing the external 5,129,285-byte NFST,
かんじ matched all synchronous segments and candidates after 10 lookup waits
and 526 logical page requests. The test simulates delayed completion by reading
the host store synchronously; it is not device or UI latency evidence. Unit
tests cover candidate parity, unpublished partial results and cancellation with
an outstanding page. The large request count, memory usage, capacity limits,
workspace integration and native SD/DMA scheduling remain open work.
