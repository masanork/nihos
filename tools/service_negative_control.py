#!/usr/bin/env python3
"""Require false-durability and cancelled-binding counterexamples."""
import difflib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    repo = Path(__file__).resolve().parent.parent
    output = Path(tempfile.mkdtemp(prefix="negative-service.", dir=repo / "build/store-service"))
    original = (repo / "src/storage/checkpoint_service.zig").read_text()
    variants = (
        ("false_ack", "            reply.visibility = .staged;", "            reply.visibility = .committed;",
         "checkpoint service owns queued copies", "FAIL (TestExpectedEqual)"),
        ("no_rollback", "if (had_staging and !self.recovery_required) self.store.rollback()", "if (false) self.store.rollback()",
         "checkpoint service exit discards successful staging", "FAIL (TestUnexpectedResult)"),
    )
    results = []
    for name, needle, replacement, test_filter, marker in variants:
        if original.count(needle) != 1:
            raise RuntimeError(f"{name} mutation is not unique")
        directory = output / name
        (directory / "storage").mkdir(parents=True)
        (directory / "kernel").mkdir()
        (directory / "root.zig").write_text('test { _ = @import("storage/checkpoint_service_test.zig"); }\n')
        for filename in ("checkpoint_model.zig", "checkpoint_service_test.zig", "extent_map.zig", "model_media.zig"):
            shutil.copy2(repo / "src/storage" / filename, directory / "storage" / filename)
        shutil.copy2(repo / "src/kernel/spsc_ring.zig", directory / "kernel/spsc_ring.zig")
        mutant = original.replace(needle, replacement)
        (directory / "storage/checkpoint_service.zig").write_text(mutant)
        (directory / "mutation.diff").write_text("".join(difflib.unified_diff(original.splitlines(True), mutant.splitlines(True), fromfile="source", tofile="mutant")))
        command = [sys.argv[1], "test", str(directory / "root.zig"), "--test-filter", test_filter]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=180)
        log = completed.stdout + completed.stderr
        (directory / "test.log").write_text(log)
        found = completed.returncode != 0 and marker in log
        results.append({"variant": name, "command": command, "exit_code": completed.returncode,
                        "semantic_counterexample_found": found, "expected_marker": marker})
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        if not found:
            raise RuntimeError(f"{name} did not find the expected counterexample: {directory}")
    print(output / "results.json")


if __name__ == "__main__":
    main()
