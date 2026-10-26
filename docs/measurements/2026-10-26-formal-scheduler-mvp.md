# Scheduler TLA+ mapping MVP

- Date: 2026-10-26
- Evidence: finite TLA+ model checking and host execution only
- Base commit: 196b354 (working-tree candidate changes are identified by hashes)
- Branch/worktree: codex/formal-scheduler-mvp / nihos-formal-mvp
- Tools: Zig 0.17.0, TLA+ tools v1.7.4 / TLC 2.19, Java 21

## Question and outcome

Can a formal scheduler model detect an implementation defect and be connected
to actual Zig state transitions with a small, reproducible bridge?

Yes, for the bounded scenario below. TLC detects starvation in the original
shared-cursor policy; its graph agrees with the unmodified Zig baseline.
The per-priority cursor candidate passes the same model requirements and
matches the model's full deterministic lasso. Reintroducing shared-cursor
behavior makes replay reject the wrong task selection.

## Scenario and results

One high-priority task repeatedly wakes, runs, and blocks. All other tasks
have equal lower priority and stay runnable. Each cycle includes an explicit
low-priority scheduling opportunity. Every low task must be selected
infinitely often under this environment.

| Tasks | Shared cursor | Per-priority cursors | Implementation replay |
| --- | --- | --- | --- |
| 3 | 5 states; liveness violation | 11 states; all properties pass | Both matching models agree |
| 4 | 5 states; liveness violation | 15 states; all properties pass | Both matching models agree |
| 5 | 5 states; liveness violation | 19 states; all properties pass | Both matching models agree |

TLC completes the reachable-state graph for every run. Safety checks include
state types, at most one running task, current/state consistency, and priority
selection. LowProgress is checked as a temporal property, including recurring
cycles. Weak fairness applies to environment progress, not to task selection.
No depth bound or state constraint is used.

In the legacy cycle only low task 2 is selected, so tasks 3..N starve.
The candidate cycles through all low tasks. Model task numbers are one-based;
the Zig task slot is one less.

For the 3-task negative control, the shared-cursor implementation replayed
against the corrected model reports:

~~~text
MODEL_MISMATCH step=5 action=schedule expected_current=3 actual_current=2
~~~

The negative control compares observable selection and task states, with
cursor checks disabled. It therefore cannot pass this test merely by finding
a difference in internal cursor representation.

## Reproduction and retained evidence

~~~sh
python3 tools/run-formal-mvp.py
~~~

The command checks all six models, six matching replays, and three deliberate
mismatches. Expected temporal violations are distinguished from tool failures.
Only a completely successful campaign writes a passed summary.

This checkout retains the final default-command run under:

- build/formal-mvp/run-y1prk0mz/summary.json
- Corresponding model directories contain TLC logs, DOT graphs, JSON traces,
  generated Zig trace data, and compiler/replay logs.

The earlier baseline campaign is retained at
build/formal-mvp/run-vgu_8jz8/summary.json. It additionally checks all three
legacy model traces against the unmodified scheduler snapshot.

- Unmodified scheduler SHA-256:
  dddd4287be294f7c581489f7cedac935a4592374992d84d3bf34b6d3bfd9665e
- Candidate scheduler SHA-256:
  b44ba5ea2f8e5388650c618eb65986d0cdb4e1e166118af220da18f0df64f0fb

Generated evidence is local and ignored by Git; rerunning creates a new,
independent artifact directory. The summary also hashes the model, bridge,
harness, mutant, and TLC jar. Input drift invalidates a run.

## Candidate change and other validation

The candidate preserves a round-robin cursor per priority, so selecting the
high-priority task does not restart the lower-priority order. A host regression
test exercises three low peers through nine high-priority wake/block cycles.

Validation completed:

- Zig host suite in Debug and ReleaseSafe.
- All 58 discovered Python tests, including six bridge rejection/coverage tests.
- Existing static analysis: formatting, ZLint, ShellCheck, RV32 contracts,
  and all six audited native ELF links.
- Replay harness formatting and ZLint separately: zero warnings.
- Diff whitespace check.

The candidate changes cursor storage from one usize to priority_levels usizes.
Native compilation is verified; runtime memory/timing measurements are not.
The original worktree and scheduler remain unchanged. Nothing is merged.

## Interpretation and next experiment

The experiment supports using TLA+ and generated replay as a regression tool
for explicit kernel contracts. Its value is demonstrated by a real defect,
a corrected implementation, and negative controls for the bridge itself.

This is not a general proof that the Zig scheduler refines TLA+. The workload
is deterministic, task counts are 3..5, and the abstraction is handwritten.
Task creation/reaping during execution, dynamic priorities, timers, wait/notify,
weak memory, traps, and hardware behavior are outside this model. Owi was not
used. Native build success is not evidence of device execution.

The next useful extension is a wait/notify model with nondeterministic posting
around wait registration, followed by a matching Zig replay adapter.

See [the model and mapping guide](../../formal/scheduler/README.md).
