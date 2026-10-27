#!/usr/bin/env python3
"""Require a semantic recovery counterexample when the first barrier is omitted."""
import difflib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def main():
    repo = Path(__file__).resolve().parent.parent
    output = Path(tempfile.mkdtemp(prefix="negative.", dir=repo / "build/checkpoint"))
    for name in ("checkpoint_model.zig", "checkpoint_model_test.zig", "model_media.zig", "file_media.zig"):
        shutil.copyfile(repo / "src/storage" / name, output / name)
    path = output / "checkpoint_model.zig"
    original = path.read_text()
    needle = "            self.device.sync() catch return self.ioFailure();\n            try self.publish(&self.staged);"
    if original.count(needle) != 1:
        raise RuntimeError("first barrier mutation is not unique")
    mutant = original.replace(needle, "            // Negative control: first durability barrier omitted.\n            try self.publish(&self.staged);")
    path.write_text(mutant)
    changes = "".join(difflib.unified_diff(original.splitlines(True), mutant.splitlines(True), fromfile="source", tofile="mutant"))
    test = output / "checkpoint_model_test.zig"
    original = test.read_text()
    mutant = re.sub(r"try equal\(@as\(usize, \d+\), (events|cuts)\);", "// The mutation changes event/case count; retain semantic checks.", original)
    test.write_text(mutant)
    changes += "".join(difflib.unified_diff(original.splitlines(True), mutant.splitlines(True), fromfile="test-source", tofile="test-mutant"))
    (output / "mutation.diff").write_text(changes)
    command = [sys.argv[1], "test", str(test), "--test-filter", "checkpoint publication"]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=120)
    log = completed.stdout + completed.stderr
    (output / "test.log").write_text(log)
    example = re.search(r"CHECKPOINT_COUNTEREXAMPLE event=(\d+) prefix=(\d+) background=(\w+) order=(\w+) recovered_generation=(\d+) error=Corrupt", log)
    passed = completed.returncode != 0 and example is not None
    result = {"schema": 1, "mutation": "omit first commit barrier only; disable event/case count assertions in copied test",
              "command": command, "exit_code": completed.returncode, "semantic_counterexample_found": passed}
    if example:
        event, prefix, background, order, generation = example.groups()
        result["counterexample"] = {"event": int(event), "prefix": int(prefix), "background": background,
                                    "order": order, "generation": int(generation), "error": "Corrupt"}
    (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    if not passed:
        raise RuntimeError(f"negative control did not find semantic failure: {output}")
    print(output / "results.json")


if __name__ == "__main__":
    main()
