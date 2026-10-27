#!/usr/bin/env python3
"""Remove payload reachability protections one at a time and require corruption."""
import difflib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    repo = Path(__file__).resolve().parent.parent
    output = Path(tempfile.mkdtemp(prefix="negative-payload.", dir=repo / "build/store-payload-gc"))
    original = (repo / "src/storage/checkpoint_model.zig").read_text()
    variants = (
        ("reader", "            for (&self.readers) |*reader| if (reader.token != 0) try self.markRoot(&reader.root, start, end);\n",
         "a pinned payload view stays valid", "PAYLOAD_PIN_COUNTEREXAMPLE error=Corrupt"),
        ("retained", "            try self.markRoot(&self.retained, start, end);\n",
         "the retained disk payload survives", "PAYLOAD_RETAINED_COUNTEREXAMPLE error=Corrupt"),
    )
    results = []
    for name, needle, test_filter, marker in variants:
        if original.count(needle) != 1:
            raise RuntimeError(f"{name} mutation is not unique")
        directory = output / name
        directory.mkdir()
        for filename in ("payload_gc_test.zig", "model_media.zig"):
            shutil.copy2(repo / "src/storage" / filename, directory / filename)
        mutant = original.replace(needle, "")
        (directory / "checkpoint_model.zig").write_text(mutant)
        (directory / "mutation.diff").write_text("".join(difflib.unified_diff(original.splitlines(True), mutant.splitlines(True), fromfile="source", tofile="mutant")))
        command = [sys.argv[1], "test", str(directory / "payload_gc_test.zig"), "--test-filter", test_filter]
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
