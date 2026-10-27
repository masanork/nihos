#!/usr/bin/env python3
"""Demand data-alias and missing-parent-publication counterexamples."""
import difflib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    repo = Path(__file__).resolve().parent.parent
    output = Path(tempfile.mkdtemp(prefix="negative-batch.", dir=repo / "build/store-batch"))
    original = (repo / "src/storage/checkpoint_model.zig").read_text()
    variants = (
        ("data_alias", ".{ .page = first + i, .checksum = checksums[i] }", ".{ .page = first + i - start, .checksum = checksums[i] }", "FAIL (Corrupt)"),
        ("parent", "                    extent_map.setChild(node, @intCast(index), updated);", "                    _ = updated; // Deliberately omit the updated child.", "FAIL (TestExpectedEqual)"),
    )
    results = []
    for name, needle, replacement, marker in variants:
        if original.count(needle) != 1:
            raise RuntimeError(f"{name} mutation is not unique")
        directory = output / name
        directory.mkdir()
        for filename in ("batch_test.zig", "extent_map.zig", "model_media.zig"):
            shutil.copy2(repo / "src/storage" / filename, directory / filename)
        mutant = original.replace(needle, replacement)
        (directory / "checkpoint_model.zig").write_text(mutant)
        (directory / "mutation.diff").write_text("".join(difflib.unified_diff(original.splitlines(True), mutant.splitlines(True), fromfile="source", tofile="mutant")))
        command = [sys.argv[1], "test", str(directory / "batch_test.zig"), "--test-filter", "batch spans all four map levels"]
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
