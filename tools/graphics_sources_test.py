"""Prepared library sources stay immutable while compilers use them."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    "graphics_sources", Path(__file__).resolve().parents[1] / "probes/graphics/fetch_sources.py")
SOURCES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOURCES)


class GraphicsSourcesTests(unittest.TestCase):
    def test_verified_cache_is_read_only_and_ignores_its_own_witness(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "library.c"
            source.write_text("patched library")
            before = source.stat().st_mtime_ns
            state = {"schema": 1, "key": "pinned", "files": SOURCES.snapshot(root)}
            (root / ".nihos-prepared.json").write_text("witness")
            SOURCES.verify_prepared(root, state, "pinned")
            self.assertEqual(source.read_text(), "patched library")
            self.assertEqual(source.stat().st_mtime_ns, before)
            with self.assertRaisesRegex(ValueError, "version"):
                SOURCES.verify_prepared(root, state, "new dependency")

    def test_changed_missing_and_added_sources_fail_without_repair(self):
        for change in ("changed", "missing", "added"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                source = root / "library.c"
                source.write_text("patched library")
                state = {"schema": 1, "key": "pinned", "files": SOURCES.snapshot(root)}
                if change == "changed":
                    source.write_text("reversed patch")
                elif change == "missing":
                    source.unlink()
                else:
                    (root / "unexpected.c").write_text("extra source")
                before = SOURCES.snapshot(root)
                with self.assertRaisesRegex(ValueError, "cache changed"):
                    SOURCES.verify_prepared(root, state, "pinned")
                self.assertEqual(SOURCES.snapshot(root), before)


if __name__ == "__main__":
    unittest.main()
