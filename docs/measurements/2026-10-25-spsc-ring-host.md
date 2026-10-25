# SMP SPSC ring host validation

- Date: 2026-10-25
- Evidence: macOS host only
- Zig: 0.17.0
- Modes: Debug and ReleaseSafe

The first native-service primitive is a fixed-capacity single-producer,
single-consumer ring. The producer and consumer own separate monotonic indices.
A release store publishes a completed slot and an acquire load accepts its
ownership on the other side. The structure contains no allocator, mutex,
wakeup, retry policy, or unbounded queue.

Host tests cover:

- empty and full queues;
- refusal to overwrite unread data;
- reuse of physical slots after logical wraparound;
- counter wrap at `maxInt(usize)`;
- exact ordering of 100,000 `u32` messages between two host threads.

The Debug suite passed 20 consecutive repetitions and a final run. The
ReleaseSafe suite also passed. This establishes host language-level behavior;
it does not qualify ESP32-P4 cache coherence, RISC-V atomic code generation,
inter-processor interrupts, scheduler wakeups, or physical cross-core latency.
Those remain native SMP hardware gates before the ring carries graphics or
SQLite service requests.

Later qualification found that the original two-value integer-wrap test was
insufficient at non-power-of-two capacities. Filling capacity 3 across wrap
reproduced unread-slot aliasing; the corrected owner-private cursor design
and stronger host/target tests are recorded in
[the event-driven channel result](2026-10-25-esp-emu-spsc-channels.md).
