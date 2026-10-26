# Scheduler formal-verification MVP

This experiment checks whether TLA+ can expose a real scheduler policy defect
and whether a small bridge can connect the model to the Zig implementation.
It is a finite, scenario-specific verification experiment, not a proof of the
whole scheduler or kernel.

## Run

From the repository root:

~~~sh
python3 tools/run-formal-mvp.py
~~~

Prerequisites are Python 3, Java, and curl. Java 21 was tested. The existing
bootstrap downloads Zig 0.17.0 if necessary. The new TLC bootstrap pins the
upstream v1.7.4 jar and checks its SHA-256 on downloads and cache hits. The jar
and all generated artifacts stay in ignored .tools/ and build/ directories.
The experiment does not change source files or require device access.

The Formal scheduler verification workflow runs this command and the bridge
regressions for pull requests and pushes to main. It retains the run directory
as the formal-scheduler-evidence artifact for 14 days, including failed runs.
The replay harness is also included in the existing static-analysis gate.

The command exits successfully only when all six model runs have their
expected outcome, all matching implementation replays pass, and all three
wrong-implementation replays fail with an observable model mismatch.
A failed download, parser failure, compilation failure, timeout, unexpected
TLC exit, or unexpected replay result fails the command.

## Requirement and environment

Task 1 is a high-priority task. Tasks 2 through N are equally prioritized low
tasks, where N is separately checked at 3, 4, and 5.

The environment repeats:

1. Select a low-priority task while the high-priority task is blocked.
2. Wake the high-priority task.
3. Schedule it.
4. Block it, leaving the next low-priority selection opportunity.

The requirement is that every low task is selected infinitely often under
this environment. Strict priority still applies. Weak fairness applies only
to progress of Next, excluding infinite stuttering when an action is enabled.
The model does not assume that the scheduler fairly chooses each task:
that is the property being checked.

TLC checks TypeOK, SingleRunning, CurrentConsistent, PrioritySelection, and
the temporal property LowProgress over the complete reachable state graph.
There is no depth bound or state constraint. The graph is finite because
task count and all modeled state domains are fixed.

## Models and implementation mapping

Global.cfg selects the legacy shared round-robin cursor. PerPriority.cfg
selects one cursor per priority. Both use the same transition definitions,
environment, invariants, and liveness property in SchedulerFairness.tla.
The runner generates equivalent configurations for N = 3, 4, and 5.

| Model | Zig implementation / abstraction |
| --- | --- |
| Task IDs 1..N | TaskHandle.slot + 1; tasks are added in slot order |
| current = 0 | current() returns null |
| states[t] | snapshot(handle).state |
| cursor[p + 1] | last_selected[p] + 1 in the candidate |
| Shared cursor[1] | Legacy scalar last_selected + 1; cursor[2] stays N |
| Init | Add high and low tasks, then block the high task |
| Schedule | schedule() |
| WakeHigh | wake(high) |
| BlockHigh | block(high) |
| phase, action | Environment/trace bookkeeping, not kernel state |

The model abstracts each API operation as one atomic step. This depends on
the existing single-owner, serialized scheduler-policy contract. Task IDs,
priorities, and generations remain fixed in this scenario. The model omits
timers, events, task exit/reuse, migration, memory ordering, and register state.

## Bridge and negative controls

The runner reads nodes and action-labelled edges from TLC's DOT graph.
For this deterministic scenario it requires one non-stuttering successor per
state, one initial state, and visitation of every reported reachable state.
It extracts a prefix and recurring cycle, then generates Zig trace data.
The host harness executes the real scheduler API and compares current task,
all task states, and cursor state after every operation. It replays the
prefix, two cycle traversals, and the closing transition.

The production source is frozen into an artifact before compilation.
A deliberate mutant changes the two per-priority cursor accesses back to
cursor index 0. This preserves the original scheduling behavior and provides
a repeatable negative control without keeping a duplicate legacy source in
the repository.

Three comparisons are required for each task count:

- Shared-cursor model versus shared-cursor mutant: states agree; TLC finds
  the starvation cycle.
- Per-priority model versus the real candidate: states agree; TLC verifies
  the stated safety and progress properties.
- Per-priority model versus the mutant: replay must reject the wrong task
  selection. Cursor comparisons are disabled for this negative control so
  representation differences cannot produce a trivial early rejection.

An optional independent legacy snapshot can also be checked:

~~~sh
python3 tools/run-formal-mvp.py --baseline /absolute/path/to/scheduler.zig
~~~

This was used to confirm the unmodified source at the start of the MVP.
The default command remains reproducible without that snapshot or Git history.

## Evidence and limits

Each run has a unique artifact directory with TLC logs, full DOT graphs,
exported trace JSON, generated replay source, compile/replay logs, frozen
candidate/mutant sources, and summary.json. The summary records source/model/
bridge/harness/tool hashes and tool versions. Live input changes during a run
invalidate the result. A successful summary is written only after every check.
Bridge parser tests run with the existing Python test discovery.

This establishes a useful regression gate for the specific scenario. It does
not establish that all input sequences of the Zig scheduler refine the model.
The abstraction and bridge are handwritten, and the compiler and TLC remain
trusted. Fixed N values do not prove a parameterized result for arbitrary N.
No native instruction execution, hardware timing, weak-memory correctness,
or Owi symbolic execution is claimed.

The candidate kernel fix keeps a cursor for each priority and adds a focused
host regression test. Cursor storage changes from one usize to priority_levels
usizes; struct padding and target-specific total size are separate concerns.
Native build checks and host tests are recorded in the measurement note.

Next useful extensions are nondeterministic wake/block interleavings and the
wait/notify no-lost-wakeup contract, with separate models and implementation
projections.

## Upstream references

- [TLA+ tools v1.7.4](https://github.com/tlaplus/tlaplus/releases/tag/v1.7.4)
- [TLA+ concepts and tools](https://lamport.azurewebsites.net/tla/tla.html)
- [Trace validation in Microsoft CCF](https://www.usenix.org/system/files/nsdi25-howard.pdf)

The released v1.7.4 command line does not support the newer dumpTrace JSON
option. This MVP uses its supported DOT export, with a deliberately narrow
parser that rejects incompatible graph shapes and state schemas.
