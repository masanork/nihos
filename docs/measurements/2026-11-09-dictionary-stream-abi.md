# Dictionary import through the checkpoint store ABI

The serialized store owner can stage dictionary key 64 using begin, copied
chunks of at most 4 KiB, finish, and the existing sync. Begin requires no
active transaction; incomplete streams cannot be committed, and abort rolls
back the import. Tokens are mount-local and not authenticated capabilities.
The caller must own the store exclusively until completion, including the
sync and any recovery after an error. A sync failure is an unknown publication
outcome; remount and independently verify before using the object. Stream
admission performs a synchronous allocation search and is not a time bound.

`store_abi_32m_probe.zig` builds a **host-only**, separate 32 MiB geometry;
freestanding compilation is rejected. The ordinary native store remains
4 MiB with the existing 1 MiB file-write limit. A caller must never interpret
the probe as permission to format, select, or migrate a physical SD card.

The host test imports a synthetic 5,129,285-byte payload, recovers the model
and compares its full SHA-256 through an object pin. It also checks the
existing 4 MiB rejection, mismatched geometry, incomplete/aborted streams,
pinned replacement, and failures before or after root publication. An
optional local run uses a caller-supplied NFST rather than vendoring it.
These are modeled callbacks and barriers, not physical power-cut, SD firmware,
native scheduling, media layout or migration evidence.
