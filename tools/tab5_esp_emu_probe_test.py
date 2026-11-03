import json
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / 'tools/tab5-esp-emu-probe.py'


class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.emulator = self.root / 'fake-emulator'
        self.emulator.write_text('''#!/usr/bin/env python3
import pathlib, sys
args = sys.argv
pathlib.Path(args[args.index('--firmware') + 1]).write_bytes(b'changed flash')
pathlib.Path(args[args.index('--efuse') + 1]).write_bytes(b'changed efuse')
print('guest reached marker')
''')
        self.emulator.chmod(0o755)
        for name in ('firmware', 'elf', 'rom', 'efuse'):
            (self.root / name).write_bytes(name.encode())

    def run_probe(self, marker):
        args = ['python3', str(PROBE), '--emulator', str(self.emulator)]
        for name in ('firmware', 'elf', 'rom', 'efuse'):
            args.extend(['--' + name, str(self.root / name)])
        args.extend(['--output', str(self.root / 'out'), '--seconds', '1', '--expect', marker])
        return subprocess.run(args, capture_output=True, text=True)

    def test_inputs_are_isolated_and_evidence_recorded(self):
        result = self.run_probe('guest reached marker')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / 'firmware').read_bytes(), b'firmware')
        self.assertEqual((self.root / 'efuse').read_bytes(), b'efuse')
        report = json.loads((self.root / 'out/report.json').read_text())
        self.assertTrue(report['expect_found'])
        self.assertNotEqual(report['inputs']['firmware']['sha256'], report['final_flash_sha256'])
        self.assertNotEqual(report['inputs']['efuse']['sha256'], report['final_efuse_sha256'])
        self.assertNotEqual(self.run_probe('guest reached marker').returncode, 0)

    def test_missing_marker_is_failure_with_receipt(self):
        result = self.run_probe('never emitted')
        self.assertNotEqual(result.returncode, 0)
        report = json.loads((self.root / 'out/report.json').read_text())
        self.assertFalse(report['expect_found'])


if __name__ == '__main__':
    unittest.main()
