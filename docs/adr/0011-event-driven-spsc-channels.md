# ADR 0011: SPSC channels use event doorbells and explicit commit results

- Status: accepted
- Date: 2026-10-25

## Decision

Connect the bounded SPSC ring to ADR 0010's latched task events through a small
generic channel. One producer owns send operations and one consumer owns
receive operations. Each endpoint reserves a single event bit: readable on
the consumer, writable on the producer. Ring storage and both endpoint
identities are initialized before either task can use the channel.

`trySend` returns full without modifying unread data. Successful publication
uses the ring's release store before notifying the consumer. `tryReceive`
copies the value out and releases its slot before notifying the producer.
The native event adapter uses the existing scalar ECALLs; no new task-call
numbers, caller pointers, heap allocation, or queue lock are required.

`send` and `receive` add blocking behavior around those operations:

1. Try the queue operation.
2. If full or empty, wait on the reserved event bit.
3. Recheck the queue after every wakeup.

The queue determines whether data or space exists; an event is only a
doorbell. A preposted event may be stale, so a wakeup never authorizes an
unchecked read or overwrite. If the peer publishes data or releases space
between the failed queue check and wait registration, its latched notification
makes that wait return. If it acts after registration, it wakes the waiter.
This relies on the serialized event owner, not an atomic transaction joining
the ring and scheduler.

Always post after a successful queue operation. An apparent empty/full or
running/waiting snapshot is insufficient to suppress notification safely.
Batch publication and notification suppression may reduce ECALL overhead
later, but need a separate race argument and measurements first.

The event-port adapter is supplied as a type, with `Handle`, `post`, and
`wait`. The native adapter is stateless. Any future stateful adapter must
support calls by both owners without introducing unsynchronized shared
mutation. Host tests inject deterministic actions at the wait boundary.

## Commitment and failure

Notification failure cannot undo a queue operation: the peer might already
be consuming the item or reusing a released slot.

| Result | Ownership and caller action |
| --- | --- |
| send `sent` | Value is in the queue; notification succeeded. |
| send `full` | Value was not queued; caller retains it. |
| send `wait_failed` | That value was not queued; caller retains it. |
| send `published_unnotified` | Value was queued; handle the notification error without blindly resending. |
| receive `item` | Value is copied out; its space-notification status is returned alongside it. |
| receive `empty` / `wait_failed` | No value was removed. |

Dead or stale task handles therefore surface as notification errors while
preserving the commit boundary. This is not a close/cancellation protocol.
A peer that dies while the other endpoint is already waiting can leave it
asleep; timeouts, termination-driven cancellation, draining, resource leases,
and channel reclamation need explicit service-lifecycle contracts. Queue
storage must remain alive until both owners are quiescent.

## Ring counter correction

Strengthening the existing wrap test found that `counter % capacity` can
alias unread slots across integer wrap when capacity is not a power of two.
Capacity 3, seeded with both empty counters at `usize.max - 1`, overwrote the
second value when the third value was queued. The earlier two-value wrap
test did not reach the alias.

Keep wrapping published counters for occupancy, but advance an owner-private
slot position modulo capacity. Group each position with its owner's atomic
publication counter and align the two groups to separate cache lines. This
supports arbitrary valid capacities without adding a cache line for each
position. The consumer copies before its release store; the producer observes
that store with acquire before reusing a slot. Neither side reads the other
side's private position.

## Validation and boundary

Host coverage includes full/empty behavior, notification ordering, stale
events, publication/release in the check-to-wait gap, both notification-error
commit boundaries, and wait errors. The ring regression fills capacity 3
across counter wrap. Two-thread tests also start near wrap and exchange
100,000 ordered values at capacities 3 and 64.

The native scenario uses two capacity-3 channels for 64 request/completion
pairs and a four-request window. It seeds both rings just before RV32 counter
wrap, forces queue-full rejection and space waiting, checks order/payloads,
checks stack canaries, and completes/reaps both tasks. Its timed service start
is a test fixture; payload progress uses channel waits rather than polling.

The native adapter is CPU0-local. SMP publication still uses release/acquire,
but CPU1 event delivery requires an owner mailbox and IPI. The existing IDF
mailbox test continues exercising transport across both cores with polling;
it does not qualify a cross-core blocking channel. Rights checks, untrusted
message validation, buffer leasing, permanent service scheduling, physical
device completion, and performance under game load remain separate steps.
