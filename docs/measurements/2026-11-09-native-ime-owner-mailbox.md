# Native sqld dictionary mailbox

The permanent sqld owner now services a single copied dictionary request
between SQLite steps. Only its registered foreground principal can submit or
take a request. It pins the reserved store key 64, reads aligned pages from
that same pinned version, and releases the pin; clients never select an
arbitrary raw key. Replies repeat the request and carry a monotonic sequence.
When the store is unavailable the owner completes a pending request with an
error; failed or short reads publish no partial bytes. A client must drain a
request before submitting another or releasing the pin. Release failure keeps
the pin; tokens are never exported to the foreground.

The host test exercises the same mailbox against the actual 4 MiB store ABI,
including replacement of the object while it is pinned. This is a host test,
not execution of the native task or SD driver. The mailbox is not yet wired
to the workspace IME: there is no dictionary provisioning, cross-core cache
qualification, hot-removal recovery or foreground adapter. The current 4 MiB
store and 1 MiB object limit cannot hold the large dictionary. No physical
Tab5, SD removal, timing or power-loss qualification has been performed.
