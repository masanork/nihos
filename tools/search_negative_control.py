#!/usr/bin/env python3
"""Require failures when search budgets or cached metadata CRC are removed."""
import difflib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    repo = Path(__file__).resolve().parent.parent
    output = Path(tempfile.mkdtemp(prefix="negative-search.", dir=repo / "build/store-search"))
    original = (repo / "src/storage/checkpoint_model.zig").read_text()
    variants = (
        ("budget", (("                    if (self.step_leaf_visits == budget.leaf_visits) return .pending;\n", ""),
                    ("                    if (self.step_bitmap_pages == budget.bitmap_pages) return .pending;\n", "")),
         "allocation search yields within both budgets", "step_leaf_visits <= budget.leaf_visits"),
        ("cache_crc", (("!pageValid(&self.cache) or std.mem.readInt(u32, self.cache[crc_offset..][0..4], .little) != ref.checksum", "std.mem.readInt(u32, self.cache[crc_offset..][0..4], .little) != ref.checksum"),),
         "metadata cache avoids backend reads", "expected error.Corrupt"),
    )
    results = []
    for name, changes, test_filter, marker in variants:
        directory = output / name
        directory.mkdir()
        for filename in ("search_cache_test.zig", "model_media.zig", "file_media.zig"):
            shutil.copy2(repo / "src/storage" / filename, directory / filename)
        mutant = original
        for needle, replacement in changes:
            if mutant.count(needle) != 1:
                raise RuntimeError(f"{name} mutation is not unique")
            mutant = mutant.replace(needle, replacement)
        (directory / "checkpoint_model.zig").write_text(mutant)
        (directory / "mutation.diff").write_text("".join(difflib.unified_diff(original.splitlines(True), mutant.splitlines(True), fromfile="source", tofile="mutant")))
        command = [sys.argv[1], "test", str(directory / "search_cache_test.zig"), "--test-filter", test_filter]
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
