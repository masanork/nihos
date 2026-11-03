#!/usr/bin/env python3
import hashlib
from pathlib import Path
import tempfile
import unittest

import sicp_257_native_emu as fixture


class Sicp257NativeFixtureTests(unittest.TestCase):
    def test_prepare_creates_hash_verified_bounded_input_and_test(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = Path(directory) / 'emu'
            receipt = fixture.prepare(destination)
            program = (destination / 'src/emu/sicp_257_input.scm').read_bytes()
            module = (destination / 'src/emu/mod.rs').read_bytes()
            self.assertEqual(receipt['scheme_bytes'], 1408)
            self.assertEqual(receipt['scheme_sha256'], hashlib.sha256(program).hexdigest())
            self.assertEqual(receipt['module_sha256'], hashlib.sha256(module).hexdigest())
            self.assertIn(b'fn sicp_257_eval_buffer_preview()', module)
            self.assertIn(b'forget-undo', module)
            self.assertIn(b'include_str!("sicp_257_input.scm")', module)
            self.assertNotIn(b"(deriv '(* x y (+ x 3)) 'x)", program)


if __name__ == '__main__':
    unittest.main()
