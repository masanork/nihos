"""The bridge must reject incomplete/ambiguous TLC graphs, not silently pass."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("formal_mvp", Path(__file__).with_name("run-formal-mvp.py"))
formal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(formal)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.graph = Path(self.directory.name) / "graph.dot"
        self.lines = []
        for node, phase, action in (
            (0, 0, "init"), (1, 1, "schedule"), (2, 2, "wake_high"),
            (3, 3, "schedule"), (4, 0, "block_high"),
        ):
            label = (
                '/\\ states = <<"blocked", "ready", "ready">>\n'
                f'/\\ action = "{action}"\n/\\ current = 0\n'
                f'/\\ phase = {phase}\n/\\ cursor = <<3, 3>>'
            )
            self.lines.append(f"{node} [label={json.dumps(label)}];")
        for source, target, action in (
            (0, 1, "Schedule"), (1, 2, "WakeHigh"), (2, 3, "Schedule"),
            (3, 4, "BlockHigh"), (4, 1, "Schedule"),
        ):
            self.lines.append(f'{source} -> {target} [label="{action}"];')

    def read(self, count=5):
        self.graph.write_text("\n".join(self.lines) + "\n")
        return formal.read_lasso(self.graph, 3, count)

    def test_complete_lasso_includes_two_cycles_and_closing_transition(self):
        steps, loop_start = self.read()
        self.assertEqual(loop_start, 1)
        self.assertEqual(len(steps), 10)
        self.assertEqual(steps[5], steps[1])
        self.assertEqual(steps[-1], steps[1])

    def test_missing_transition_is_rejected(self):
        self.lines.pop()
        with self.assertRaisesRegex(RuntimeError, "missing/extra source"):
            self.read()

    def test_nondeterministic_graph_requires_explicit_bridge_extension(self):
        self.lines.append('1 -> 2 [label="WakeHigh"];')
        with self.assertRaisesRegex(RuntimeError, "nondeterministic"):
            self.read()

    def test_truncated_graph_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "state-count mismatch"):
            self.read(count=6)

    def test_changed_state_schema_is_rejected(self):
        self.lines[0] = self.lines[0].replace("cursor", "unmapped_cursor")
        with self.assertRaisesRegex(RuntimeError, "Unexpected TLC state fields"):
            self.read()

    def test_unrecognized_action_is_rejected(self):
        self.lines[-1] = '4 -> 1 [label="UnmodeledAction"];'
        with self.assertRaisesRegex(RuntimeError, "Unknown graph edge"):
            self.read()


if __name__ == "__main__":
    unittest.main()
