# Paged dictionary to conventional IME: host integration

The experimental adapter passes copy-out candidates from a pinned paged NFST
reader to the existing bunsetsu conversion engine. The engine copies candidate
bytes before the next lookup. A lookup error is sticky through a conversion;
the IME discards partial segments, preserves the reading, and reports the
error. The reader itself remains invalid after an I/O failure until reopened.
The adapter records whether any lookup truncated candidates to eight.

With an externally supplied 5,129,285-byte SKK-JISYO.L-derived NFST, the host
test streams the object into the experimental checkpoint store, closes and
recovers it, pins it, and types `kanji`, Space, Space, Enter through the
conventional IME. The preedit changes from 漢字 to 幹事 and the document
receives 幹事. In this run the preceding lookups plus the conversion incurred
302 page-cache misses; this is not an interactive latency measurement.

```sh
NIHOS_NFST_PATH=/path/to/jisyo-l.nfst \
  .tools/zig-0.17.0/zig test -O ReleaseSafe -lc \
  src/paged_ime_large_host_test.zig --test-filter 'large paged dictionary drives IME'
```

The test does not redistribute the external dictionary. The bridge is
synchronous and experimental: it does not register a native storage driver,
provide an SD mount/import workflow, schedule bounded I/O, or integrate the
adapter into the workspace. No physical device or power-loss behavior was tested.
