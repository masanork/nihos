#!/usr/bin/env python3
"""Check finite TLA+ models and replay their complete deterministic lassos."""

import argparse
import hashlib
import json
import platform
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / "formal/scheduler/SchedulerFairness.tla"
SCHEDULER = ROOT / "src/kernel/scheduler.zig"
FIELDS = {"states", "cursor", "current", "phase", "action"}
ACTIONS = {"Schedule": "schedule", "WakeHigh": "wake_high", "BlockHigh": "block_high"}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(command, log, *, cwd=ROOT, timeout=120):
    started = time.monotonic()
    result = subprocess.run(
        [str(arg) for arg in command], cwd=cwd, capture_output=True,
        text=True, timeout=timeout,
    )
    output = result.stdout + result.stderr
    log.write_text(output)
    return result.returncode, output, round(time.monotonic() - started, 3)


def parse_state(label, task_count):
    values = {}
    for line in label.splitlines():
        match = re.fullmatch(r'/\\ (\w+) = (.+)', line)
        require(match is not None, f"Unrecognized TLC state line: {line!r}")
        name, value = match.groups()
        require(name not in values, f"Duplicate state field: {name}")
        if value.startswith("<<") and value.endswith(">>"):
            value = "[" + value[2:-2] + "]"
        values[name] = json.loads(value)
    require(set(values) == FIELDS, f"Unexpected TLC state fields: {set(values)}")
    require(len(values["states"]) == task_count, "Wrong task count")
    require(all(s in ("ready", "running", "blocked") for s in values["states"]), "Bad task state")
    require(len(values["cursor"]) == 2, "Wrong cursor count")
    require(all(type(c) is int and 1 <= c <= task_count for c in values["cursor"]), "Bad cursor")
    require(type(values["current"]) is int and 0 <= values["current"] <= task_count, "Bad current")
    require(type(values["phase"]) is int and values["phase"] in range(4), "Bad phase")
    require(values["action"] in {"init", *ACTIONS.values()}, "Unknown action")
    return values


def read_lasso(graph, task_count, distinct_count):
    """Read TLC's DOT graph; reject nondeterminism or incomplete coverage.

    This scenario intentionally has exactly one non-stuttering successor per
    state. No general TLA+ expression parser or graph-search oracle is hidden
    in the bridge: the node values and edges come from TLC.
    """
    nodes, edges = {}, {}
    for line in graph.read_text().splitlines():
        node = re.fullmatch(r'(-?\d+) \[label=("(?:\\.|[^"\\])*").*', line)
        edge = re.fullmatch(r'(-?\d+) -> (-?\d+) \[label="(\w+)".*', line)
        if edge:
            source, target, name = edge.groups()
            require(name in ACTIONS, f"Unknown graph edge: {name}")
            edges.setdefault(source, []).append((target, ACTIONS[name]))
        elif node:
            identifier, label = node.groups()
            require(identifier not in nodes, "Duplicate graph node")
            nodes[identifier] = parse_state(json.loads(label), task_count)
    require(len(nodes) == distinct_count, "TLC graph/state-count mismatch")
    initials = [key for key, value in nodes.items() if value["action"] == "init"]
    require(len(initials) == 1, "Expected one initial state")
    require(set(edges) == set(nodes), "Graph has missing/extra source nodes")
    require(all(len(successors) == 1 for successors in edges.values()), "Scenario is nondeterministic")
    ordered, positions = [], {}
    current = initials[0]
    while current not in positions:
        require(current in nodes, "Graph edge targets a missing node")
        positions[current] = len(ordered)
        ordered.append(nodes[current])
        target, action = edges[current][0]
        require(target in nodes and nodes[target]["action"] == action, "Action/target mismatch")
        require(nodes[target]["phase"] == (nodes[current]["phase"] + 1) % 4, "Phase mismatch")
        current = target
    require(len(ordered) == len(nodes), "Graph contains unvisited states")
    loop_start = positions[current]
    # Replay the complete prefix and two traversals of the recurring cycle,
    # including the closing transition, rather than only a finite prefix.
    cycle = ordered[loop_start:]
    steps = ordered + cycle + [cycle[0]]
    return steps, loop_start


def check_model(jar, work, count, per_priority):
    name = "per-priority" if per_priority else "global"
    directory = work / f"{name}-{count}"
    directory.mkdir()
    (directory / MODEL.name).write_bytes(MODEL.read_bytes())
    config = directory / "Model.cfg"
    config.write_text(
        f"CONSTANTS\nTaskCount = {count}\nPerPriority = {str(per_priority).upper()}\n"
        "SPECIFICATION Spec\n"
        "INVARIANTS TypeOK SingleRunning CurrentConsistent PrioritySelection\n"
        "PROPERTY LowProgress\n"
    )
    graph = directory / "graph.dot"
    code, output, elapsed = run([
        "java", "-Xmx512m", "-XX:+UseParallelGC", "-cp", jar, "tlc2.TLC",
        "-workers", "1", "-seed", "1", "-fp", "0",
        "-config", config.name, "-metadir", directory / "states",
        "-dump", "dot,actionlabels", graph, MODEL.name,
    ], directory / "tlc.log", cwd=directory)
    if per_priority:
        require(code == 0 and "Model checking completed. No error has been found." in output,
                f"Corrected model failed; see {directory / 'tlc.log'}")
    else:
        require(code == 13 and "Temporal properties were violated." in output,
                f"Expected liveness counterexample missing; see {directory / 'tlc.log'}")
        require("Back to state " in output and "counter-example:" in output,
                "Expected a cyclic counterexample")
    counts = re.findall(r"([\d,]+) states generated, ([\d,]+) distinct states found, 0 states left on queue", output)
    require(counts, "TLC did not complete its reachable-state search")
    distinct_count = int(counts[-1][1].replace(",", ""))
    steps, loop_start = read_lasso(graph, count, distinct_count)
    cycle = steps[loop_start:distinct_count]
    served = sorted({s["current"] for s in cycle if s["action"] == "schedule" and s["current"] > 1})
    expected = list(range(2, count + 1)) if per_priority else [2]
    require(served == expected, f"Unexpected low-task cycle: {served}")
    trace_path = directory / "trace.json"
    trace_path.write_text(json.dumps({
        "task_count": count, "loop_start": loop_start,
        "distinct_states": distinct_count, "steps": steps,
    }, indent=2) + "\n")
    return {
        "model": name, "task_count": count, "distinct_states": distinct_count,
        "tlc_exit": code, "expected_liveness_violation": not per_priority,
        "low_tasks_in_cycle": served, "elapsed_seconds": elapsed,
    }, steps, directory


def replay(zig, source, directory, count, steps, name, *, check_cursors=True, mismatch=False):
    data = directory / f"{name}-trace.zig"
    rows = []
    for step in steps:
        states = ", ".join("." + value for value in step["states"])
        cursor = ", ".join(str(value) for value in step["cursor"])
        rows.append(
            "    .{ .action = ." + step["action"] + f", .current = {step['current']}, "
            ".states = .{ " + states + " }, .cursor = .{ " + cursor + " } },"
        )
    data.write_text(
        f"pub const task_count = {count};\n"
        f"pub const check_cursors = {str(check_cursors).lower()};\n"
        "const Step = struct {\n"
        "    action: enum { init, schedule, wake_high, block_high },\n"
        "    current: usize,\n"
        "    states: [task_count]enum { ready, running, blocked },\n"
        "    cursor: [2]usize,\n"
        "};\n"
        "pub const steps = [_]Step{\n" + "\n".join(rows) + "\n};\n"
    )
    executable = directory / name
    code, _, _ = run([
        zig, "build-exe", "-O", "ReleaseSafe", "--dep", "scheduler", "--dep", "trace_data",
        f"-Mroot={ROOT / 'formal/scheduler/replay.zig'}",
        f"-Mscheduler={source}", f"-Mtrace_data={data}", f"-femit-bin={executable}",
    ], directory / f"{name}-build.log")
    require(code == 0, f"Zig replay build failed: {directory / (name + '-build.log')}")
    code, output, _ = run([executable], directory / f"{name}.log")
    if mismatch:
        require(code != 0 and "MODEL_MISMATCH" in output, "Bridge failed to reject wrong scheduling")
    else:
        require(code == 0 and "REPLAY_OK" in output, f"Zig/model mismatch: {directory / (name + '.log')}")
    return {"name": name, "exit": code, "expected_mismatch": mismatch, "states": len(steps)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/formal-mvp")
    parser.add_argument("--baseline", type=Path, help="Optional unmodified legacy scheduler snapshot")
    args = parser.parse_args()
    base = args.output.resolve()
    base.mkdir(parents=True, exist_ok=True)
    # Unique directories prevent stale success logs/traces being reused.
    work = Path(tempfile.mkdtemp(prefix="run-", dir=base))
    print(f"Artifacts: {work}", flush=True)
    jar = subprocess.check_output(["sh", str(ROOT / "tools/bootstrap-tlc.sh")], text=True).strip()
    zig = subprocess.check_output(["sh", str(ROOT / "tools/bootstrap-zig.sh")], text=True).strip()
    source = SCHEDULER.read_text()
    candidate = work / "candidate_scheduler.zig"
    candidate.write_text(source)
    token = "self.last_selected[priority]"
    require(source.count(token) == 2, "Candidate cursor layout changed; review mutation/projection")
    mutant = work / "shared_cursor_mutant.zig"
    mutant.write_text(source.replace(token, "self.last_selected[0]"))
    require(mutant.read_text() != source, "Mutation did not change source")
    summary = {
        "scope": "finite deterministic repeated-high-wakeup scenario; host replay",
        "platform": platform.platform(), "scheduler_sha256": sha256(SCHEDULER),
        "git_head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "model_sha256": sha256(MODEL), "bridge_sha256": sha256(Path(__file__)),
        "harness_sha256": sha256(ROOT / "formal/scheduler/replay.zig"),
        "tlc_jar_sha256": sha256(Path(jar)),
        "mutant_sha256": sha256(mutant),
        "java_version": subprocess.run(["java", "-version"], capture_output=True, text=True, check=True).stderr.strip(),
        "zig_version": subprocess.check_output([zig, "version"], text=True).strip(),
        "models": [], "replays": [],
    }
    if args.baseline:
        require(args.baseline.resolve() != SCHEDULER.resolve(), "Baseline must be an independent snapshot")
        summary["baseline_sha256"] = sha256(args.baseline)
    for count in (3, 4, 5):
        for per_priority in (False, True):
            result, steps, directory = check_model(jar, work, count, per_priority)
            summary["models"].append(result)
            implementation = candidate if per_priority else mutant
            summary["replays"].append(replay(
                zig, implementation, directory, count, steps, "matching-implementation",
            ))
            if args.baseline and not per_priority:
                summary["replays"].append(replay(
                    zig, args.baseline.resolve(), directory, count, steps, "unmodified-baseline",
                ))
            if per_priority:
                # Ignore representation-only cursor differences here: this
                # negative control must fail on observable task selection/state.
                summary["replays"].append(replay(
                    zig, mutant, directory, count, steps, "reject-wrong-implementation",
                    check_cursors=False, mismatch=True,
                ))
            print(
                f"{result['model']} tasks={count}: {result['distinct_states']} states, "
                f"expected TLC result and Zig replay confirmed", flush=True,
            )
    # Reject results if live inputs drifted during the run.
    for path, key in (
        (SCHEDULER, "scheduler_sha256"), (MODEL, "model_sha256"),
        (Path(__file__), "bridge_sha256"),
        (ROOT / "formal/scheduler/replay.zig", "harness_sha256"),
    ):
        require(sha256(path) == summary[key], f"Source changed during verification: {path}")
    if args.baseline:
        require(sha256(args.baseline) == summary["baseline_sha256"], "Baseline changed during verification")
    # A report is published only after every required check succeeds.
    summary["status"] = "passed"
    report = work / "summary.json"
    report.write_text(json.dumps(summary, indent=2) + "\n")
    print(f"MVP passed: {report}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"FORMAL_MVP_FAILED: {error}", file=sys.stderr)
        sys.exit(1)
