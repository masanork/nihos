import hashlib
import fcntl
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / 'tools/hosted-udp-layout.py'
spec = importlib.util.spec_from_file_location('hosted_udp_layout', SCRIPT)
layout = importlib.util.module_from_spec(spec)
spec.loader.exec_module(layout)


class HostedUdpLayout(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run([sys.executable, str(SCRIPT)], cwd=ROOT, text=True,
                                capture_output=True, check=True)
        cls.report = json.loads(result.stdout)
        cls.elf = (layout.OUT / 'layout.o').read_bytes()

    def test_report_matches_object_assembly_and_inputs(self):
        self.assertEqual(layout.symbol_sizes(self.elf), self.report['sizes_bytes'])
        self.assertEqual(hashlib.sha256(self.elf).hexdigest(), self.report['object_sha256'])
        self.assertEqual(hashlib.sha256((layout.OUT / 'layout.s').read_bytes()).hexdigest(),
                         self.report['assembly_sha256'])
        self.assertEqual(self.report['target'], 'riscv32-freestanding-none')
        self.assertEqual(self.report['zig_version'], '0.17.0')
        self.assertEqual(set(self.report['source_inputs_sha256']), set(layout.INPUTS))
        for name, digest in self.report['source_inputs_sha256'].items():
            self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), digest)

    def test_rejects_truncated_wrong_architecture_and_missing_marker(self):
        for bad in (self.elf[:20], b'\0' + self.elf[1:], self.elf[:18] + b'\0\0' + self.elf[20:],
                    self.elf.replace(b'udp_layout_sender\0', b'udp_layout_sendeX\0')):
            with self.subTest(length=len(bad)), self.assertRaises(ValueError):
                layout.symbol_sizes(bad)

    def test_failed_compile_removes_prior_success_receipt(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            (out / 'report.json').write_text('{"old": true}')
            with mock.patch.object(layout, 'OUT', out), \
                 mock.patch.object(layout, 'source_receipt', return_value={}), \
                 mock.patch.object(layout.subprocess, 'check_output', side_effect=['zig\n', '0.17.0\n']), \
                 mock.patch.object(layout.subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'zig')):
                with self.assertRaises(subprocess.CalledProcessError):
                    layout.main()
            self.assertFalse((out / 'report.json').exists())

    def test_changed_input_during_build_does_not_publish_receipt(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            (out / 'report.json').write_text('{"old": true}')

            def produce(args, **_kwargs):
                obj = next(Path(arg.split('=', 1)[1]) for arg in args if arg.startswith('-femit-bin='))
                asm = next(Path(arg.split('=', 1)[1]) for arg in args if arg.startswith('-femit-asm='))
                obj.write_bytes(self.elf)
                asm.write_text('mock assembly')

            with mock.patch.object(layout, 'OUT', out), \
                 mock.patch.object(layout, 'source_receipt', side_effect=[{'head': 'old'}, {'head': 'new'}]), \
                 mock.patch.object(layout.subprocess, 'check_output', side_effect=['zig\n', '0.17.0\n']), \
                 mock.patch.object(layout.subprocess, 'run', side_effect=produce):
                with self.assertRaisesRegex(RuntimeError, 'source changed'):
                    layout.main()
            self.assertFalse((out / 'report.json').exists())

    def test_writer_waits_for_existing_lock(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)
            marker = out / 'started'
            child_source = (
                'import importlib.util, pathlib, sys; '
                's=importlib.util.spec_from_file_location("layout_child", sys.argv[1]); '
                'm=importlib.util.module_from_spec(s); s.loader.exec_module(m); '
                'm.OUT=pathlib.Path(sys.argv[2]); pathlib.Path(sys.argv[3]).write_text("ready"); '
                'm.main()'
            )
            with (out / '.lock').open('a+') as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                child = subprocess.Popen([sys.executable, '-c', child_source, str(SCRIPT), str(out), str(marker)],
                                         cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                try:
                    deadline = time.monotonic() + 10
                    while not marker.exists() and time.monotonic() < deadline:
                        if child.poll() is not None:
                            break
                        time.sleep(0.02)
                    self.assertTrue(marker.exists(), 'child did not reach the lock')
                    with self.assertRaises(subprocess.TimeoutExpired):
                        child.wait(timeout=0.2)
                    self.assertFalse((out / 'report.json').exists())
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    stdout, stderr = child.communicate(timeout=30)
                    self.assertEqual(child.returncode, 0, stderr)
                    report = json.loads(stdout)
                    self.assertEqual(hashlib.sha256((out / 'layout.o').read_bytes()).hexdigest(),
                                     report['object_sha256'])
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate()


if __name__ == '__main__':
    unittest.main()
