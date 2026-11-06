# Resumable NFST lookup prototype

The experimental lookup parser now consumes a bounded number of byte or state
steps per call and returns a page request rather than reading the store itself.
The caller supplies a tagged completion through the page coordinator. Candidate
bytes remain private until the lookup completes. Cancellation with a request in
flight keeps the coordinator attached until the producer has completed; failed,
short, stale and malformed responses do not publish a result.

For five readings in an external 5,129,285-byte NFST recovered from the host
checkpoint store, the resumed parser matched the synchronous reader's candidate
lists and truncation flags. The harness synchronously reads the pinned host
object to simulate each delayed completion; this validates the continuation and
handoff, not concurrent or native I/O. With the coordinator's single page cache,
these five lookups made 465 logical page requests. The current prototype reads
child pointer bytes incrementally and does not use the synchronous reader's
multi-page caches, so this is not a performance improvement.

One `Lookup` exclusively owns its coordinator during a lookup; the caller must
serialize access, maintain the real object pin, and ensure a completed producer
has stopped using its buffer before supplying it. A step budget bounds parser
operations, not transport latency or scheduler response time. Conversion and
workspace still use the synchronous reader; native SD RPC, DMA cancellation,
UI scheduling and Tab5 tests are not implemented here.
