# Workspace async IME dispatch prototype

The workspace can attach a caller-owned async IME port. When attached, the
first Space starts the resumable conversion through the workspace key handler;
the owner calls `pollAsyncIme` to advance it and separately supplies completed
pages. Repeated Space while a page is pending is ignored. Other input first
cancels the conversion and then follows the existing input path; Escape/Cancel
stops conversion while preserving the reading. The port cannot detach until a
cancelled page request drains. A poll that makes no visible change does not
increment the workspace render revision.

In a host test, `kanji`, Space, page completion, Space, Enter all went through
the workspace key handler and committed 幹事 using a recovered 5,129,285-byte
NFST. The simulated host page producer made 138 logical requests. Tests also
cover typing and committing while a cancelled page is draining, and reject
port detachment before completion. Without an attached port the existing
built-in dictionary path remains in use.

The event loop in this test explicitly calls `pollAsyncIme`; it synchronously
reads a host-backed store to simulate page completion. No native event loop
attaches this port, and no SD RPC, DMA lifecycle, memory placement, Tab5 input,
physical timing or power-loss test is established. The port and its underlying
pin must stay alive until all requests are drained and detachment succeeds.
