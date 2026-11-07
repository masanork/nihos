# Resumable NFST child-table locality

The resumed parser now copies the current node's child pointer table into a
bounded 1,020-byte buffer before visiting child edges. This prevents a
single-page coordinator from repeatedly switching between the parent pointer
page and child pages. Loading remains incremental, and no step issues an I/O
itself. The table is bounded by NFST's 255-child encoding; all offsets remain
validated before use.

With the external 5,129,285-byte NFST recovered from a file-backed checkpoint
store, five lookup comparisons required 68 logical page requests instead of
465. Full async-style conversion of かんじ required 138 instead of 526
requests and produced the same segments and candidates. Adapter size increased
from 27,848 to 28,872 bytes on this host. Both runs use simulated page arrival;
these counts do not establish SD performance or Tab5 response time.

A separate fixture puts a child table across a 4 KiB boundary and checks
cancellation while waiting for its second page, drain before detachment, and
successful lookup after reattachment. Native async SD I/O, DMA lifetime,
workspace wiring, memory placement and physical device testing remain open.
