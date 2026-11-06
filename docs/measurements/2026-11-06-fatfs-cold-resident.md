# FatFs RPC fixture resident budget

The opt-in FatFs RPC link fixture exceeded the cold-placement resident limit on
main. Place the heap test worker and SQLite test failure reporter in the
existing mapped-Flash cold extent. The former runs as a test task and already
calls the cold object probe; the latter is called only by the cold SQLite probe.
Allocator APIs, interrupt entry and cache-control code remain resident. The
explicit policy and image audit still check each permitted function and the
8 KiB resident headroom requirement.

The local FatFs RPC link and image audit report 105,984 resident bytes, below
the 106,496-byte limit. This is a link-time fixture, not physical execution or
a proof of all interrupt and cache-disabled call paths.
