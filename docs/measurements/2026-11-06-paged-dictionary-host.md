# Paged dictionary reader over experimental checkpoint store

This is an opt-in host experiment, not a native SD integration or a stable
on-disk format. The existing checkpoint/COW engine is an experimental
log-structured storage component; this experiment does not implement SQLite
WAL, an SD service, full-volume GC, or physical power-loss qualification.

`src/storage/nfst_reader.zig` uses a caller-supplied immutable, pinned
random-access reader and one 4 KiB cache. It bounds the search key and copies
up to eight UTF-8 candidates to caller-owned storage. Extra candidates set a
truncation flag. Bounds/version errors and short/failed I/O fail closed; after
an I/O error the reader is unusable. Its owner must invalidate the dictionary
before releasing the underlying pin or changing the object. The current regular
file experiment uses a single contiguous stream allocation; it does not prove
admission or availability under fragmentation or near-full conditions.

The automated test uses a synthetic NFST that crosses a 4 KiB boundary, in a
5 MiB-plus object on a 16 MiB host file. It checks streaming, commit, close,
remount, pinned lookup, an oversized admission failure, replacement with an
old pinned reader, and explicit invalidation. Separate controls cover invalid
header, invalid child, candidate bounds, invalid UTF-8, and failed/short I/O.
Host file sync is not a physical-media durability guarantee.

The optional test uses a caller-provided NFST, without adding third-party
wordlists to this repository. On this host, the cached `SKK-JISYO.L` input
SHA-256 was `c791f578d1b4040fce282db29bc22b2cc7ea46f83e269fab2e0fa779e2967e40`;
its header specifies GPL-2.0-or-later. The compiler produced 147,498 entries,
5,129,285 bytes, SHA-256
`b2f9b0026fafcd3b6fc4e8287c7e06472c4314c88e9231ce6d83d8a10b7e56f8`.
The test streams it to a temporary 16 MiB host file, closes and reopens the
store, and checks representative candidates and one absent reading. Seven
lookups caused 110 cache misses in the 4 KiB dictionary cache. This is a count
of cache refills, not a Tab5 latency or SD read count. An earlier six-query
version made 514 misses when the child offset table was fetched repeatedly;
copying that bounded table once reduced the same six-query run to 87 misses.

Reproduce with the pinned Zig and a separately obtained, licensed SKK-JISYO.L:

```sh
python3 tools/dict_compiler.py /path/to/SKK-JISYO.L -o /tmp/nihos-jisyo-l
NIHOS_NFST_PATH=/tmp/nihos-jisyo-l_nfst.bin \
  .tools/zig-0.17.0/zig test -lc -O ReleaseSafe \
  src/storage/nfst_large_host_test.zig --test-filter 'large dictionary stream'
.tools/zig-0.17.0/zig test -O ReleaseSafe src/storage/nfst_reader_test.zig
```

Next: adapt bunsetsu conversion to the bounded reader without repeatedly
blocking the foreground owner; validate candidate coverage and latency; bind
the store through native owner/IPC with precise pin lifetime and SD error
handling. Separately integrate transaction reservation into all writers and
SQLite/WAL, then validate near-full recovery and physical power cuts. A larger
dictionary alone does not demonstrate WAL/FS integration or GB-scale operation.
