# Paged IME root-page cache

NFST trie searches revisit the first page. The experimental reader retains
that immutable page separately from its existing 4 KiB data page. Both caches
are invalidated on an I/O error or when the dictionary is closed; both refer to
the same pinned object. This costs an additional 4 KiB per reader. An opt-out
permits direct comparison, but does not recover the reserved memory.

On the 5,129,285-byte external dictionary in the file-backed host checkpoint
store, with the per-conversion existence memo enabled in both runs and caches
cold at conversion start:

| Romaji input | Single page | Root plus data page |
| --- | ---: | ---: |
| kanji | 138 | 132 |
| kyouhaiitenkidesune | 1,569 | 1,403 |
| watashihagakuseidesu | 1,070 | 966 |

The test also compares every returned segment and candidate, and tests cache
invalidation after a read error. These are logical host reader fetches, not SD
transactions or device latency. The modest reduction leaves hundreds or
thousands of synchronous fetches; it does not solve native scheduling or
establish interactive responsiveness. The workspace still uses its built-in
dictionary.
