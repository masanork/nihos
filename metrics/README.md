# Project metrics

![Source growth](code-size.svg)

![Host Zig emitted-line coverage](coverage.svg)

The [current summary](summary.md) and [daily history](history.json) distinguish
source volume from execution coverage. PR CI produces a `project-metrics`
artifact containing the per-file inventory, SHA-256 hashes, JSON summary,
charts, and raw kcov HTML/XML. A successful push to `main` also records one
snapshot per **UTC day**, replacing that day's earlier point. The publication
job preserves the measured commit and skips publication if `main` advances;
it never rebases old measurements onto new source. A bot commit made with
`GITHUB_TOKEN` does not trigger another push workflow. Branch rules must allow
that bot push for automatic publication; the artifact remains available if
publication fails.

The initial point is a frozen local working-tree baseline, not a successful
hosted CI run. Its [MeOS comparison and validation record](../docs/measurements/2026-10-25-code-metrics.md)
documents the measured boundary and concurrent-work snapshot.

## Source-size scope

Python 3 and Git are the only requirements for source-size measurements:

```sh
python3 tools/metrics.py
python3 tools/metrics.py --compare ../MeOS
python3 tools/metrics.py --coverage build/metrics/host-coverage.json --record
```

Outputs default to ignored `build/metrics/`. `--compare` reads the other
checkout without modifying it. `--record` updates this directory's history,
charts and summary; omit it for a temporary report. The comparison report
describes **current working-tree bytes**, including untracked, non-ignored
source. It is not a comparison of released versions. Commit ID, dirty state,
measurement time and a source-inventory fingerprint identify the snapshot.
The CI artifact's `current.json` also records each measured file's hash.

- Count physical lines, including comments and blank lines, as in mikaki's
  tracker. A final line without a newline still counts. These are not semantic
  statements, firmware bytes, linked code, complexity, productivity or feature
  parity measurements.
- nihos product roots: `src`, `compat`, `include`, `main`. MeOS product roots:
  `kernel`, `hal`, `drivers`, `fs`, `user`, `apps`, `main`, `components`.
- Count `.zig`, `.c`, `.h`, `.S`/`.s`, `.inc`, `.rs`, `.py`, `.sh`.
  Documentation, CMake/configuration, build outputs, installed SDKs and managed
  components are excluded. Files come from deduplicated `git ls-files -co
  --exclude-standard`, not a recursive count of build/download caches.
- Dedicated test filenames/directories and Zig `test` blocks count as tests.
  The Zig heuristic balances braces after masking comments, strings, character
  literals and multiline strings. Helpers outside inline test blocks remain
  implementation; dedicated test files include their helpers. The production
  renderer `src/graphics/test_pattern.zig` is explicitly exempt from the
  filename rule. Target scenario files named `_test.zig` are test code; other
  embedded bring-up/diagnostic code remains implementation. This is a source
  convention, not a semantic partition or a claim that every test was run.
- Non-test code in `tools/` and `build.zig` counts as tooling. Test harnesses,
  including tool regression tests, count as tests and can be distinguished by
  `byArea`. Language-comparison `probes/` count separately.
- `third_party/` counts as vendored source, separately from project code.
  MeOS font/image/dictionary files listed in `MEOS_DATA` in
  `tools/metrics.py` count as generated/data. Entire mixed font/data decoder
  files are assigned to that category, including small decoder functions.
  This classification does not imply ownership or licensing conclusions.
- The source chart stacks implementation, tests and tooling. Probes, vendored
  libraries and generated data stay in the numerical report. This avoids
  obscuring project growth with font tables and third-party engines.

## Execution-coverage scope

On Linux, after installing the dependencies listed in
`tools/bootstrap-kcov.sh`:

```sh
sh tools/bootstrap-zig.sh
python3 tools/host_coverage.py --kcov "$(sh tools/bootstrap-kcov.sh)"
python3 tools/metrics.py --coverage build/metrics/host-coverage.json
```

The collector builds the `src/root.zig` test root with the `ccid`, `surface`
and `canvas` module bindings from `build.zig` and Debug optimization. Other
standalone test roots in `zig build test` are outside this collection. It
executes the root binary directly and under checksum-pinned
[kcov v43](https://github.com/SimonKagstrom/kcov/tree/v43), and counts emitted
DWARF implementation lines below `src/`. Test files and inline `test` blocks
are removed from the percentage. HTML/XML retain the raw collector view,
including tests; the filtered implementation numerator/denominator is in
`host-coverage.json`. Source hashes must match when importing coverage, and a
fresh collection directory prevents old runs' hits from being merged.

**This is host-test emitted-line coverage, not whole-kernel coverage.** Zig's
lazy compilation and DWARF mapping omit unreferenced functions, comptime-only
work and uncompiled hardware files from the denominator. The report lists
represented and unrepresented source files, but does not invent executable
line counts for absent files. C/assembly, ESP-IDF, ESP-EMU, and physical Tab5
execution are outside this measurement. Hardware and target qualification
remain separate evidence.

The first local baseline uses Linux ARM64 in Docker on macOS; hosted CI uses
Linux x86-64. Emitted-line denominators can differ with host architecture and
compiler backend, so changes in that environment must accompany interpretation
of a coverage trend. kcov pins traced execution to one CPU. The host thread tests yield while
waiting for queue space or data, so the peer can progress without waiting for
a full scheduler time slice. The collector has a five-minute execution limit.
Coverage runs in its own CI job, separately from the normal quality gates.

Without a matching measured report, coverage is `null`/unavailable and the
chart has a gap. Test source divided by total source is never presented as
coverage. MeOS execution coverage is currently unavailable in this comparison;
its host/device tests were not rerun or instrumented by the comparison tool.

Linux containers need ptrace permission, e.g. `--cap-add SYS_PTRACE
--security-opt seccomp=unconfined`. The local macOS source-size report does not
require Docker or kcov.
