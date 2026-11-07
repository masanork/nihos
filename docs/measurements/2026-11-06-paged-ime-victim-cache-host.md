# Paged IME previous-page cache

An experimental 4 KiB previous-page slot retains the data page displaced by
the next fetch. Hits read directly from that slot; a miss copies the current
page into it before fetching. It is not LRU. I/O error or reader invalidation
clears all page-valid flags. The slot costs 4 KiB in addition to the existing
4 KiB root and 4 KiB data slots; disabling it does not free the allocation.

Using the external 5,129,285-byte NFST in the file-backed host checkpoint
store, with the root cache and existence memo enabled in both cases, and cold
page caches at the beginning of each conversion:

| Romaji input | Root and data pages | Plus previous page |
| --- | ---: | ---: |
| kanji | 132 | 75 |
| kyouhaiitenkidesune | 1,403 | 1,093 |
| watashihagakuseidesu | 966 | 762 |

Segments, candidate lists, and preedit matched. This counts logical page
fetches only; it does not measure memcpy cost, RAM placement, device latency,
SD commands, or responsiveness. The UI still uses the built-in dictionary and
the experimental reader remains synchronous. Asynchronous scheduling and
physical measurement remain necessary.
