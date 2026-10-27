#!/usr/bin/env python3
"""Check that omitted reader/disk-root reachability corrupts a protected view."""
import difflib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    repo = Path(__file__).resolve().parent.parent
    output = Path(tempfile.mkdtemp(prefix="negative-index.", dir=repo / "build/store-index-gc"))
    original = (repo / "src/storage/checkpoint_model.zig").read_text()
    variants = (
        ("reader", "            for (&self.readers) |*reader| if (reader.token != 0 and rootReferences(&reader.root, page)) return true;\n", "",
         "pinned snapshots survive metadata reuse", "PIN_COUNTEREXAMPLE current_generation=5 error=Corrupt"),
        ("retained", "rootReferences(&self.current, page) or rootReferences(&self.retained, page) or", "rootReferences(&self.current, page) or",
         "both valid disk roots survive", "RETAINED_ROOT_COUNTEREXAMPLE error=Corrupt"),
    )
    results = []
    for name, needle, replacement, test_filter, marker in variants:
        if original.count(needle) != 1:
            raise RuntimeError(f"{name} mutation is not unique")
        directory = output / name
        directory.mkdir()
        for filename in ("index_gc_test.zig", "model_media.zig", "extent_map.zig"):
            shutil.copy2(repo / "src/storage" / filename, directory / filename)
        mutant = original.replace(needle, replacement)
        (directory / "checkpoint_model.zig").write_text(mutant)
        (directory / "mutation.diff").write_text("".join(difflib.unified_diff(original.splitlines(True), mutant.splitlines(True), fromfile="source", tofile="mutant")))
        command = [sys.argv[1], "test", str(directory / "index_gc_test.zig"), "--test-filter", test_filter]
        completed = subprocess.run(command, capture_output=True, text=True, timeout=120)
        log = completed.stdout + completed.stderr
        (directory / "test.log").write_text(log)
        found = completed.returncode != 0 and marker in log
        results.append({"variant": name, "command": command, "exit_code": completed.returncode,
                        "semantic_counterexample_found": found, "expected_marker": marker})
        if not found:
            (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            raise RuntimeError(f"{name} did not find the expected counterexample: {directory}")
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(output / "results.json")


if __name__ == "__main__":
    main()
