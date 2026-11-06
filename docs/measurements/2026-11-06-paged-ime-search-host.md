# Paged IME repeated lookup experiment

The bunsetsu dynamic program asks whether the same stem exists many times.
The paged adapter now memoizes up to 64 existence answers for the duration of
one conversion. Keys are bounded to 64 bytes; when the table is full or a key
is longer, lookup proceeds normally. It stores no candidate pointers. Failed
lookups are never cached, and starting another conversion clears all answers.
This adds approximately 4.2 KiB to the experimental adapter, in addition to
the existing page and candidate buffers.

On the externally supplied 5,129,285-byte SKK-JISYO.L-derived NFST, a
file-backed checkpoint store was recovered and pinned. Each comparison begins
with the single 4 KiB page cache invalidated. Candidate lists, segment counts,
and visible preedit were identical with the memo enabled and disabled:

| Romaji input | Page fetches before | Page fetches after | Memo hits |
| --- | ---: | ---: | ---: |
| kanji | 192 | 138 | 4 |
| kyouhaiitenkidesune | 4,372 | 1,569 | 294 |
| watashihagakuseidesu | 3,492 | 1,070 | 224 |

Run using the external dictionary and the command in
`2026-11-06-paged-ime-host.md`. Fetch counts include conversion only, not
loading the store or typing the reading. These are logical reader fetches on
one host workload, not SD commands or Tab5 latency. The remaining fetches and
the synchronous implementation still rule out drawing conclusions about UI
responsiveness; a bounded asynchronous native read path and device measurement
are still needed.
