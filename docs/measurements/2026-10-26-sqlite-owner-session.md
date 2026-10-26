# Three follow-ups: class quotas, C identity, SQLite owner session

- Date: 2026-10-26
- Continuation base: `9a237c5f74484f3ef1bf0d77c01280152b22db1f`
- Remote base before the accumulated changes: `a7bc2f9ae2a57618b59e6605f3931e295e086556`
- [Source-bound aggregate data](2026-10-26-sqlite-owner-session.json)
- Decisions: [quota configuration](../adr/0038-configured-size-class-quotas.md),
  [task identity](../adr/0039-runtime-c-task-identity.md),
  [SQLite session](../adr/0040-bounded-single-owner-sqlite-session.md)

## Three local stages

1. Per-class quotas are copied into the task's internal-SRAM ledger. Zero
   disables a class; no implicit fallback/growth is added. A trace-informed
   C profile initially requested 47,184 bytes / one 64 KiB block and passed the
   original host SQLite workload plus all 308 OOM/retry points. Its exact
   [intermediate evidence](2026-10-26-configured-class-quotas.json) is preserved.
2. A nonzero C task identity includes owner hart, scheduler slot and generation.
   It remains stable across pool operations, changes on task reuse and rejects
   masked/native interrupt-context use. Host current-task state is thread-local;
   the heap remains single-owner. See the distinct
   [intermediate evidence](2026-10-26-c-task-identity.json).
3. A bounded host SQLite session checks that identity before entering the
   globally configured THREADSAFE=0 library. It owns initialization, connection,
   statements and shutdown; rejects wrong-owner entry; supports copied integer/
   null scalar results, VM-budget interruption and atomic token cancellation.

The recursive-query test exhausted the original forty 128-byte cells. The
final profile increases only that class to 64 cells, giving quotas
`24,12,16,12,64,4,8,12,8,1`: 50,640 requested bytes and a 65,536-byte outer block.
The default equal-quota probe still requests 534,336 bytes / a 1 MiB block.
Thus this finite configured workload uses one sixteenth of that parent
reservation. Native service suitability or all-query capacity is not claimed.

## Host results

- Zig Debug / ReleaseSafe: 148 tests passed in each mode.
- Python native log/image/compiler regressions: 84 passed.
- Zig format, ZLint, ShellCheck and three-language ABI probe passed.
- The C caller checks profile selection, capacity-copy semantics, OOM,
  wrong/interior/freed pointers, task retirement and thread-local identities.
- SQLite 3.54.1's original memory workload still passes all 308 injected OOM
  points and retries for both equal quotas and the configured profile. Maximum
  request is 2048 bytes; its peak usable bytes remain 27,456 and remaining bytes
  after connection close are zero. These metrics describe the original workload,
  not the extended session's maximum memory use.
- The session workload passes 321 separately injected allocation failures,
  successful retries, zero retained parents and normal shutdown. It checks a
  scalar result, schema creation, transaction/rollback and a subsequent insert.
- Wrong-task open/eval/close are refused before SQLite entry. A pre-existing
  caller pool survives failed initialization. Owner retirement returns all
  memory; the new generation is refused access to old global library state.
  This final case deliberately leaves the library unusable until process restart.
- SQL length (512), single-statement and result limits are checked. Multiple
  result rows/columns, result types other than integer/null and write RETURNING are rejected;
  the RETURNING fixture verifies no row was inserted. Caller PRAGMA and ATTACH
  requests are denied, preserving the configured database limits.
- A long recursive SELECT is interrupted by the VM progress budget. A real
  pthread in another host task cancels the active token without calling SQLite.
  Its own direct SQL entry is refused. A later SELECT succeeds. Old tokens do
  not cancel an idle/new request, and token exhaustion refuses further queries
  while allowing shutdown.
- A separate normal executable with all injection hooks compiled out returns
  42, closes and recovers the heap. Clang static analysis emits zero diagnostics.

The initial four-column SQLite limit prevented its own schema setup and was
corrected to sixteen. The recursive test initially returned NOMEM under the
forty-cell class policy; it passed budget/cancel tests after the measured quota
change above. Both failures informed the final bounded configuration.

## Native qualification

The final source executes the entire existing nine-case matrix: integer with
absent/4/8/16/32/64 MiB, raw FP absent, and compiled Zig/C FP absent/32 MiB.
Six full device/emulator images and their ELF/instruction/loader audits pass.
Each saved emulator case retains its exact ELF, app/merged images, layout,
audit, log and report. Two C probes per populated hart and zero per absent hart
are required. Their extra configured-profile open/close and identity checks
preserve the old 300-round scheduler/lifecycle/IPI/WFI/FP/heap recovery evidence.

| Mode | Previous total static at 9a237c5 | Current total static | Growth | Internal heap | App image |
| --- | ---: | ---: | ---: | ---: | ---: |
| Integer | 129,536 B | 133,248 B | 3712 B | 87,936 B | 79,216 B |
| Raw FP | 133,696 B | 137,408 B | 3712 B | 83,776 B | 82,368 B |
| Compiled FP | 133,952 B | 137,664 B | 3712 B | 83,520 B | 82,688 B |

Both revision profiles have these sizes. The 57,344-byte separate stack region
and primary 163,840-byte region are unchanged. Minimum internal heap remains
34,368 bytes above the 48 KiB gate. The growth includes canonical quota storage,
configuration code, C identity and additional probe operations, so it is not
an isolated allocator cost. SQLite session code contributes no native bytes.
The baseline uses its preceding recorded image audits, not a new rebuild.

## Boundaries and reproduction

```sh
sh tools/run-sqlite-memory-probe.sh
build/sqlite/memory-probe profile
.tools/zig-0.17.0/zig build test
.tools/zig-0.17.0/zig build test -Doptimize=ReleaseSafe
python3 -m unittest discover -s tools -p 'native*_test.py'
sh tools/run-static-analysis.sh
sh tools/run-native-smoke.sh compiled 32M
sh tools/build-native.sh device compiled
```

The working checkout is `/private/tmp/nihos-c-allocator`. The original dirty
repository and its unrelated local commits were not changed. A former tool
symlink pointed through a removed old checkout; it was repaired to point at
the existing repository tool installation, without modifying that installation.

The aggregate JSON records source digests, exact native images/reports and host
executables/logs. Intermediate stage images are retained separately. Current
remote workflows are separate evidence and run after the accumulated push.
No physical device was accessed. Host pthread cancellation is not native SMP
SQLite execution. Native library placement/runtime/stack size, a real service
task and bounded RPC, persistent VFS fault tests, Flash/cache pause/resume,
physical timing and storage/power recovery remain separate gates.
