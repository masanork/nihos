# Host workspace to pinned checkpoint page owner

An experimental copy-only queue connects the workspace async IME port to a
serialized checkpoint-store owner. The owner creates and retains an object
pin, binds one page-coordinator generation, validates request sequence and
bounds, and reads that pinned value into owner-owned storage. A workspace-side
client accepts only the exact outstanding response. Cancellation discards the
result but does not release the pin until the request has returned, the client
has stopped, and both queues have drained.

The host integration imported and recovered the external 5,129,285-byte NFST,
then ran `kanji`, Space, Space, Enter through the actual workspace input path.
The store owner was stepped every third foreground iteration; the session made
138 page requests and 440 foreground iterations and committed 幹事. A stale
response was discarded without satisfying the live request. A second conversion
was cancelled after the owner queued a reply; the port and pin could not close
until the reply was consumed. Another test replaced the committed object while
an old version was pinned and verified the owner still read the old version.

This is a host prototype, not native scheduling or an SD driver. Owner
`readPinnedWithScratch` is synchronous, and the caller must serialize all
store access, attest client shutdown before closing, and establish DMA/cache
coherency and shared-memory placement. A queued request is not a native task,
thread or physical SD completion. No Tab5 input, timing, removal, restart or
power-loss behavior was tested.
