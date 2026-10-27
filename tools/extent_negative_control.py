#!/usr/bin/env python3
"""Require counterexamples when shared-data, node, or summary marking is omitted."""
import difflib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    repo = Path(__file__).resolve().parent.parent
    output = Path(tempfile.mkdtemp(prefix="negative-extents.", dir=repo / "build/store-extents"))
    original = (repo / "src/storage/checkpoint_model.zig").read_text()
    variants = (
        ("data", "                for (0..count) |i| self.markPhysicalPage(extent_map.data(&self.map_buffer, i).page);\n", "",
         "pinned mapped data and map nodes survive", "EXTENT_READER_COUNTEREXAMPLE error=Corrupt"),
        ("nodes", "            self.markPhysicalPage(ref.page);\n", "            _ = ref; // Deliberately omit node reachability.\n",
         "pinned mapped data and map nodes survive", "EXTENT_READER_COUNTEREXAMPLE error=Corrupt"),
        ("node_summary", "if (!child.data.intersects(self.search.start, self.search.end) and !child.nodes.intersects(self.search.start, self.search.end)) continue;",
         "if (!child.data.intersects(self.search.start, self.search.end)) continue;",
         "internal node summaries protect metadata far", "FAIL (TestExpectedEqual)"),
    )
    results = []
    for name, needle, replacement, test_filter, marker in variants:
        if original.count(needle) != 1:
            raise RuntimeError(f"{name} mutation is not unique")
        directory = output / name
        directory.mkdir()
        for filename in ("extent_map_test.zig", "extent_map.zig", "model_media.zig", "file_media.zig"):
            shutil.copy2(repo / "src/storage" / filename, directory / filename)
        mutant = original.replace(needle, replacement)
        (directory / "checkpoint_model.zig").write_text(mutant)
        (directory / "mutation.diff").write_text("".join(difflib.unified_diff(original.splitlines(True), mutant.splitlines(True), fromfile="source", tofile="mutant")))
        command = [sys.argv[1], "test", str(directory / "extent_map_test.zig"), "--test-filter", test_filter]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=180)
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
