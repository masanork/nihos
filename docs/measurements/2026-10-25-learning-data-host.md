# Learning application data and compiler sizing

- Date: 2026-10-25
- Evidence: macOS arm64 host sizing and RV32 compilation only
- Device execution: none; no flash or partition changes
- Python SQLite: 3.54.0, FTS5 enabled
- Target SQLite object: official amalgamation 3.54.1
- Zig: repository-pinned 0.17.0

This probe supports the [learning applications proposal](../planning/learning-applications.md).
It measures experimental search projections, not production dictionary packs or
ESP32-P4 query latency. Existing kernel work was not modified.

## Sources and reproducibility

The aggregate [JSON record](2026-10-25-learning-data-host.json) contains source
URLs, archive sizes, SHA-256 hashes, record counts, database sizes, and query
results. Original dictionaries, book archives, and generated databases remain
under ignored `build/app-study/`; they are not checked into the repository.

```sh
python3 tools/research/measure-learning-data.py
```

The script downloads missing inputs but reuses cached archives. Its default
output is `build/app-study/results.json`. To measure a newly downloaded daily
release without replacing an old experiment, use another directory:

```sh
python3 tools/research/measure-learning-data.py --root build/app-study-next
```

The host must provide Python with FTS5 and the trigram tokenizer. No third-party
Python packages are needed. Dictionary data is obtained from the
[EDRDG archive](https://www.edrdg.org/pub/Nihongo/), and the book list and three
text archives from Aozora Bunko. See the
[EDRDG data licence](https://www.edrdg.org/edrdg/licence.html) and
[Aozora handling rules](https://www.aozora.gr.jp/guide/kijyunn.html).

| Input | Compressed bytes | Uncompressed XML bytes |
| --- | ---: | ---: |
| JMdict_e.gz | 10,588,094 | 63,189,643 |
| kanjidic2.xml.gz | 1,488,582 | 15,641,823 |
| Aozora extended UTF-8 catalogue ZIP | 2,092,746 | not an XML input |

The downloaded catalogue had 19,502 rows representing 17,840 unique work IDs.
This is a snapshot of that catalogue, not an independently audited count of all
currently available works. Multiple people can produce multiple rows per work.

The selected work IDs were 000789, 000773, and 000456. Each had its work
copyright flag set to `なし`. The UTF-8 sizes of their decoded text files were
1,120,767, 559,512, and 127,706 bytes. Annotations and colophons were retained.
This probe does not implement a complete Aozora parser.

## Database layout

Each base database contains:

- `entries(id, headwords, readings, body)`;
- `forms(term, entry_id, kind)` and a B-tree on `(term,entry_id)`;
- 4096-byte pages.

Dictionary forms use host Python's NFKC and case folding. This is not yet a
complete Japanese reading normalization policy. Headwords and readings are
joined for display; English glosses are flattened for the sizing experiment.
Sense applicability, POS, cross-references, frequency, stroke counts, radicals,
and other dictionary attributes are not all retained. A real learning pack
must preserve the attributes its UI promises to display.

Each FTS variant uses external content in `entries`, avoiding a second FTS copy
of the same text. Variants use `unicode61,detail=full`,
`trigram,detail=full`, or `trigram,detail=none,columnsize=0`.
The build performs FTS rebuild, optimize, integrity check, and VACUUM.

Book text is split into 1024-character chunks for sizing only. Production
passage boundaries and references should follow paragraphs and source positions.

Host index construction uses `journal_mode=OFF` and `synchronous=OFF` on
disposable databases. These settings are not the durability policy for user
data; the latter remains the separately fault-tested system-service design.

## Measured sizes

All sizes below include the source projection, forms, B-tree, and relevant FTS
tables. They are not index-only sizes. MiB means 1,048,576 bytes.

| Corpus | Records | Projected UTF-8 text | Base DB | unicode61 full | trigram full | trigram none |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| JMdict English projection | 218,957 | 15.33 MiB | 48.49 MiB | 65.44 MiB | 101.97 MiB | 65.68 MiB |
| KANJIDIC2 projection | 13,108 | 0.61 MiB | 2.84 MiB | 3.61 MiB | 4.86 MiB | 3.36 MiB |
| Three Aozora books | 597 chunks | 1.72 MiB | 2.34 MiB | 3.89 MiB | 6.73 MiB | 4.09 MiB |

The JMdict projection has 499,496 normalized form records; KANJIDIC2 has
50,156. The intentionally simple forms table repeats strings in both its table
and index. These numbers do not claim an optimal compact dictionary schema.

The book trigram totals are about 2.37 and 3.91 times the projected text for
the none and full variants. Applying those ratios to another collection is an
estimate: document length, repeated text, annotations, language, and segmentation
all affect the ratio. No full-library Aozora or Wikipedia index was built.

## Bounded SQLite read probe

For each variant, a fresh Python worker opens the DB read-only and immutable
with `mmap_size=0`, `cache_size=-1024`, `temp_store=MEMORY`, and
`hard_heap_limit=4194304`. All specified queries completed without SQLite
allocation failure. Dictionary queries include exact form lookups and applicable
FTS or substring lookups. The selected book trigram query returned four chunks.

The limit covers SQLite's tracked allocator, not Python, UI, VFS, file cache,
Wasm, or total process memory. It proves that these queries over these databases
can execute with this SQLite allocator limit on the host. It does not bound
every future SQL statement or prove SD responsiveness on Tab5.

The JSON retains seven-sample warm median host query times as diagnostic data.
The OS file cache remains warm; those numbers must not be reported as device
latency. The device evaluation needs cold and warm reads, storage service
accounting, query cancellation, simultaneous rendering, and SD error handling.

SQLite memory accounting must remain enabled if relying on its hard heap
limit. A custom capped allocator is another option; a page-cache target alone
does not cap total query memory.

## Japanese tokenizer checks

With the test sentence `私は日本語の辞書を作る。` in a built-in trigram table:

| Query | MATCH count | LIKE count |
| --- | ---: | ---: |
| 日本 | 0 | 1 |
| 日本語 | 1 | 1 |
| 辞書 | 0 | 1 |

On the JMdict trigram-none database, `MATCH '"日本語"'` found 34 records;
`MATCH '"日本語辞典"'` failed with
`fts5: phrase queries are not supported (detail!=full)`.
This agrees with the constraints described in the
[FTS5 trigram documentation](https://sqlite.org/fts5.html#the_trigram_tokenizer).
The LIKE operator working does not mean a short pattern used an index.

## RV32 SQLite object size

The official SQLite 3.54.1 amalgamation archive was downloaded from
`https://sqlite.org/2026/sqlite-amalgamation-3540100.zip`.
Its SHA3-256 was
`92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30`,
matching the [official download page](https://sqlite.org/download.html).

The local Espressif GCC 14.2.0 toolchain (`esp-14.2.0_20260121`) compiled
`sqlite3.c` with:

```text
-Os -march=rv32imafc_zicsr_zifencei -mabi=ilp32f
-ffunction-sections -fdata-sections
-DSQLITE_OS_OTHER=1 -DSQLITE_THREADSAFE=0
-DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_WAL
-DSQLITE_DEFAULT_MEMSTATUS=1 -DSQLITE_OMIT_DEPRECATED
```

The second object additionally enables `-DSQLITE_ENABLE_FTS5`.
GNU `size` reports text as code plus read-only sections.

| Object | text | data | bss |
| --- | ---: | ---: | ---: |
| SQLite core | 509,145 | 6,240 | 658 |
| SQLite plus FTS5 | 617,046 | 6,240 | 658 |

The FTS5 addition is 107,901 text bytes for this build. These are unlinked
objects; final section garbage collection, runtime support, VFS, RPC, and
application references affect final firmware size. The bss column is not the
SQLite working heap. No nihos firmware linked or executed SQLite in this probe.

## Zig compilation probe

The repository-pinned macOS Zig executable is approximately 190 MiB on disk.
The test source was:

```zig
export fn sum_to(n: u32) u32 {
    var sum: u32 = 0;
    var index: u32 = 0;
    while (index < n) : (index += 1) sum +%= index;
    return sum;
}
```

It was built with `zig build-exe`, target `wasm32-freestanding`,
`-fno-entry --export=sum_to -O ReleaseSmall`, once with the default backend
and once with `-fno-llvm`. Each cold build used a distinct, empty local and
global cache directory. `/usr/bin/time -l` measured the host compiler process:

| Condition | Maximum RSS | Peak footprint | Output Wasm |
| --- | ---: | ---: | ---: |
| Default backend, cold cache | 291,241,984 bytes | 252,904,288 bytes | 84 bytes |
| No LLVM backend, cold cache | 291,946,496 bytes | 253,297,504 bytes | 438 bytes |

Both modules were instantiated with Node WebAssembly and `sum_to(10)` returned
45. Warm-cache observations were much smaller, around 81.5 to 92.3 MiB maximum
RSS, showing why cache conditions must be recorded. The initial unexported
module was not used as the functional result.

These host measurements do not establish a minimum RAM requirement for a
stripped, RV32-hosted compiler. They also do not show that the compiler can run
on nihos. Native compiler hosting still requires an OS/runtime/allocator/linker
port and a separate memory evaluation. The successful Wasm output proves a
PC-side cross-compilation path, not Tab5 self-hosting.
