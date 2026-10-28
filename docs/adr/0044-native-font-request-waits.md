# 0044: Bounded requests and blocking waits for the native font fixture

Status: accepted for local emulator qualification, 2026-10-28.

Retain one CPU0 font task across client closes. Use the existing task-call
event ABI and two existing SPSC channels, each with two slots: bootstrap
submits requests, the font task returns replies. One dispatcher owns submission;
multiple applications must not write this SPSC endpoint concurrently. A future
broker or separate client channels must define that application boundary.

The experimental protocol copies a nonzero ordered request ID and a typed
`render_matrix` or `stop` operation. Replies copy the ID, operation, retained
charge and the complete 16-case hash matrix. No application pointer or mutable
font/face object crosses the boundary. This is a qualification protocol, not
a paragraph, glyph-buffer or application session API. The native harness
requests four matrices and then stops; it does not qualify arbitrary workloads
or early cancellation of the C++ oracle.

The font task publishes each complete reply, then receives another request.
An empty channel blocks through `wait_events`; latched notifications cover
the empty-check-to-wait gap. A failed notification after publication is not
permission to resubmit an item. The fixture fails explicitly on transport
errors instead of attempting cancellation or recovery.

Stop is ordered after all completed renders. The client must copy its terminal
reply and finish the channel's space notification before posting a distinct
terminal acknowledgment. The font task waits for that acknowledgment before
returning through EXIT. Queue-empty alone cannot authorize EXIT: a consumer
releases a slot before notifying its producer, leaving a scheduling window
where the producer endpoint must remain alive. Force a task yield inside this
window in the qualification fixture. Queues remain statically reserved after
both endpoints finish, with no post-reap notifications or reuse claimed.

Require five observed request waits, each spanning at least two real native
ticks with unchanged font-task runtime. Require all five requests/replies,
terminal acknowledgment, empty queues and final task-ledger heap recovery.
Record matrix hashes, fixed queue bytes, SRAM reservations and stack observation
against exact image bytes. This proves font-task blocking, not whole-system
WFI, power consumption or physical timing; bootstrap remains the active driver.

Service restart, application routing/cancellation, SD/VFS inputs and physical
Tab5 qualification remain separate gates. [Native graphics notes](../native-graphics.md)
record the current candidate and measurements.
