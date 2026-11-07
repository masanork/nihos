# Host workspace composition with resumable dictionary

An experimental host-driven session prepares the existing workspace's romaji
composition, holds the reading and caret snapshot while a paged conversion
runs, then publishes the completed candidates through the existing preedit
state. If the reading, caret, document revision, or preedit changes while
waiting, it abandons the old cursor and drains any in-flight page before reuse.
It does not clear an engine that a newer synchronous conversion already reused.

The host test enters `kanji` through the actual scratch model, starts the
session in place of the initial Space event, simulates page completions, then
uses the model's Space and Enter handlers to select and commit 幹事. With the
external 5,129,285-byte NFST stored in a recovered, pinned host checkpoint
object, this required 138 logical page requests and 183 session steps. The
host harness reads the store synchronously to simulate each completion.
Separate tests change the composition during a page wait and start a newer
synchronous conversion; neither publishes stale results or loses the new text.

This is not yet wired into the workspace input dispatcher or any native worker.
The harness explicitly starts and polls the session; page RPC, DMA lifetime,
pin authentication, memory placement, scheduling, SD performance and Tab5
interaction remain untested. The dictionary and session must have exclusive,
serialized owners until cancellation has drained outstanding requests.
