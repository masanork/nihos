# Cooperative conversion prototype

`SlicedConversion` performs at most the requested number of phrase evaluations,
backtracking operations, candidate populations, or state transitions per call.
It does not publish a segment count until candidate population completes.
Cancellation and dictionary errors clear the partial result; the caller owns the
engine and must keep the same immutable, pinned dictionary for the whole job.

Host tests compare each segment and candidate to synchronous conversion, use a
one-unit budget, cancel at several progress points, and inject an I/O error. In
a file-backed checkpoint store using the external 5,129,285-byte NFST, the
reading きょうはいいてんきですね produced identical candidates after 276
pending returns with a one-unit budget. The cursor occupies 2,288 bytes on
this host, excluding the engine, reader, adapter, and cache buffers.

This is a scheduling boundary, not an asynchronous storage implementation. A
single phrase evaluation or candidate population may itself synchronously issue
many reads; the unit budget does not bound elapsed time, individual SD commands,
or DMA lifetime. No workspace integration, native scheduler, Tab5 latency, or
physical cancellation was tested. A future native worker must supply real
non-blocking I/O and own cancellation/drain and dictionary pin lifetimes.
