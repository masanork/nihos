#!/usr/bin/env python3
"""Require semantic failures for incomplete publication and cancelled ownership."""
import difflib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    repo = Path(__file__).resolve().parent.parent
    output = Path(tempfile.mkdtemp(prefix="negative-stream.", dir=repo / "build/store-stream"))
    original = (repo / "src/storage/checkpoint_model.zig").read_text()
    rollback = """        pub fn rollback(self: *Self) Error!void {
            try self.transaction();
            self.invalidateSearch();
            self.writer.token = 0;
            self.in_transaction = false;
        }"""
    variants = (
        ("incomplete", "            if (self.writer.received != self.writer.length) return error.IncompleteStream;\n", "",
         "stream declared length prepared allocation", "expected error.IncompleteStream"),
        ("cancel", rollback, rollback.replace("            self.writer.token = 0;\n", ""),
         "stream cancellation preserves earlier staged work", "FAIL (Busy)"),
    )
    results = []
    for name, needle, replacement, test_filter, marker in variants:
        if original.count(needle) != 1:
            raise RuntimeError(f"{name} mutation is not unique")
        directory = output / name
        directory.mkdir()
        for filename in ("stream_test.zig", "model_media.zig"):
            shutil.copy2(repo / "src/storage" / filename, directory / filename)
        mutant = original.replace(needle, replacement)
        (directory / "checkpoint_model.zig").write_text(mutant)
        (directory / "mutation.diff").write_text("".join(difflib.unified_diff(original.splitlines(True), mutant.splitlines(True), fromfile="source", tofile="mutant")))
        command = [sys.argv[1], "test", str(directory / "stream_test.zig"), "--test-filter", test_filter]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=120)
        log = completed.stdout + completed.stderr
        (directory / "test.log").write_text(log)
        found = completed.returncode != 0 and marker in log and "FAIL (" in log
        results.append({"variant": name, "command": command, "exit_code": completed.returncode,
                        "semantic_counterexample_found": found, "expected_marker": marker})
        if not found:
            (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            raise RuntimeError(f"{name} did not find the expected counterexample: {directory}")
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(output / "results.json")


if __name__ == "__main__":
    main()
