# IME page queue backed by the serialized store ABI

`ime_page_queue.AbiStore` adapts the object-pin, copied read and release ABI to
the existing page queue owner. The store owner must serialize all access, keep
the adapter and mount alive, and drain the client and both queues before
release. Tokens are mount-local and are not authorization or protection
against a remount; this adapter must not outlive its mount.

The host test uses the real store ABI over an in-memory 4 MiB medium. It checks
pinned old bytes after replacement, stale requests, backend read failure,
draining and release; after recovery it imports the bundled small NFST and
drives workspace `kanji` through the ABI-backed queue to the committed `漢字`.

This is not hooked into the native task scheduler. The current ABI is still
limited to a 4 MiB store and 1 MiB writes, so this does not install the large
dictionary. Native task ownership, queue placement/coherency and shutdown,
safe capacity migration, real SD I/O and Tab5 operation remain unverified.
