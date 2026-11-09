# Read-only SD capacity candidate

`tools/nihos_sd_capacity_plan.py` examines a previously captured 512-byte MBR
sector and an independently supplied card size. It never opens a raw device or
writes a file. It accepts only the current `NIHSQLD1` marker and exact legacy
first partition (LBA 2048, 8192 sectors, type `0xda`), matching the current
native recognizer. The proposed 32 MiB range begins at the next 1 MiB boundary
after all declared primary partitions and uses a fully empty table slot.

The tool rejects invalid signatures and entries, overlap, out-of-bounds ranges,
multiple active entries, extended or GPT-protective entries, a full table,
insufficient capacity and sizes outside the MBR address range. Tests also check
that its legacy constants still match the native code. It accepts only an exact
512-byte regular-file capture and refuses symbolic links and device nodes.

```sh
python3 tools/nihos_sd_capacity_plan.py /path/to/sector0.bin \
  --card-sectors 123456789
```

Output includes a SHA-256 of the supplied capture, the supplied card size,
legacy and other declared partition ranges, and a candidate range. A candidate
means only **unallocated according to that MBR**: unpartitioned sectors can
still contain data, and this tool cannot establish capture freshness, card
identity, hidden metadata, filesystem state, or exclusive ownership. The 32 MiB
size is a planning choice, not a proof of adequate future write reservation.
It does not authorize or perform formatting, a partition-table update, copying,
selector publication or cutover. The current native raw owner still admits only
the legacy range. No live card, device timing or physical power-loss test was
performed.
