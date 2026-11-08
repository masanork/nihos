# Host copy to a larger checkpoint store

This experiment copies a pinned committed source volume into a separately
formatted, empty checkpoint store. It streams every present key in one target
transaction, preserves blob versus mapped representation, and checks key
presence, kind, length and bytes against the source before reporting success.
It never formats or writes the source. Caller-supplied domain identifiers are
assertions only; a native caller must independently prove device ranges do not
overlap and retain exclusive ownership. Object pins/snapshots, token values,
generation numbers and uncommitted transactions are not migrated.

A host fixture created by the real SQLite service occupied a 4 MiB legacy
image and contained a table row `(1, 日本語)`. The test copied its two store
objects (20,496 bytes) into a separate 32 MiB image, imported an external
5,129,285-byte NFST as key 200, reopened the target, and compared every source
object with the target while verifying the source image SHA-256 was unchanged.
A copied database extracted from the reopened target passed SQLite
`PRAGMA integrity_check` and returned the original row; the added dictionary
returned 漢字 for かんじ. The dictionary is not redistributed by this test.

A separate model sampled 56 destination write/sync cuts across two writeback
policies, including points near the final publication; after modeled restart
the target was either empty or contained the complete original object set,
and the source digest remained unchanged. This is bounded fault sampling,
not exhaustive cut-point coverage or physical power-loss qualification.

This is not an on-device migrator or a selector/cutover protocol. The copy
function verifies the currently mounted target; the host test separately
reopens it. No MBR/GPT, SD range disjointness, capacity reservation for future
writes, concurrent SQLite writers, user snapshots, native scheduler, DMA or
Tab5 was tested. A failed or interrupted target must not be selected; commit
failure may have an unknown outcome and requires recovery and revalidation.

Reproduce with a separately obtained NFST dictionary and the pinned toolchain:

```sh
sh tools/build-sqld-host.sh
work=$(mktemp -d /tmp/nihos-capacity-copy.XXXXXX)
build/sqld/sqld-host --create "$work/legacy.img" <<'SQL'
2 0 0 0 CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT)
2 0 0 0 INSERT INTO notes VALUES(1, '日本語')
1 0 0 0 SELECT * FROM notes
SQL
NIHOS_LEGACY_IMAGE="$work/legacy.img" \
NIHOS_NFST_PATH=/path/to/jisyo-l.nfst \
NIHOS_MIGRATED_DB="$work/migrated.db" \
  .tools/zig-0.17.0/zig test -O ReleaseSafe -lc \
  src/capacity_copy_large_host_test.zig --test-filter 'larger host store'
python3 - "$work/migrated.db" <<'PY'
import sqlite3, sys
c = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
assert c.execute('PRAGMA integrity_check').fetchall() == [('ok',)]
assert c.execute('SELECT id, body FROM notes').fetchall() == [(1, '日本語')]
PY
```
