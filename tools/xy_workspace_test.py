#!/usr/bin/env python3
"""SQLite + shared-VM integration, including real process restart and failures.
Build first with tools/build-xy-mac.sh. All databases are temporary.
"""
import ctypes as c
import os
from pathlib import Path
import sqlite3
import hashlib
import json
import struct
import zlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
HOST = Path(os.environ.get('XY_MAC_HOST', ROOT / 'build/xy-mac/xy-mac-host'))


class WorkspaceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not HOST.is_file():
            raise RuntimeError('Build tools/build-xy-mac.sh before running these tests')
        cls.store = c.CDLL(str(HOST.parent / 'libxy_workspace.dylib'))
        cls.store.xy_workspace_open.argtypes = [c.c_char_p]
        cls.store.xy_workspace_open.restype = c.c_void_p
        cls.store.xy_workspace_close.argtypes = [c.c_void_p]
        cls.store.xy_workspace_error.argtypes = [c.c_void_p]
        cls.store.xy_workspace_error.restype = c.c_char_p
        cls.store.xy_workspace_save.argtypes = [c.c_void_p, c.c_char_p, c.c_uint32, c.c_int64, c.POINTER(c.c_int64)]
        cls.store.xy_workspace_load.argtypes = [c.c_void_p, c.c_int64, c.c_void_p, c.c_uint32, c.POINTER(c.c_int64)]
        cls.store.xy_workspace_select.argtypes = [c.c_void_p, c.c_int64, c.c_int64]
        cls.vm = c.CDLL(str(HOST.parent / 'libxy_host.dylib'))
        cls.vm.xy_host_live_prepare.argtypes = [c.c_char_p, c.c_uint32]
        cls.vm.xy_host_live_prepare.restype = c.c_bool
        cls.vm.xy_host_live_activate.restype = c.c_bool
        cls.vm.xy_host_live_run.argtypes = [c.c_char_p, c.c_uint32, c.c_bool, c.c_void_p, c.c_uint32]
        cls.vm.xy_host_buffer_copy.argtypes = [c.c_void_p, c.c_uint32]

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='xy-workspace-')
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'workspace.db'

    def cli(self, action, *args, ok=True):
        result = subprocess.run([str(HOST), '--workspace-cli', str(self.path), action, *map(str, args)], capture_output=True, timeout=10)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr.decode())
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def apply(self, source, ok=True):
        path = Path(self.temp.name) / 'init.scm'
        path.write_bytes(source)
        return self.cli('apply-file', path, ok=ok)

    def connect(self):
        handle = self.store.xy_workspace_open(os.fsencode(self.path))
        self.assertTrue(handle)
        self.assertEqual(self.store.xy_workspace_error(handle), b'')
        self.addCleanup(self.store.xy_workspace_close, handle)
        return handle

    def save(self, handle, source, expected):
        revision = c.c_int64()
        code = self.store.xy_workspace_save(handle, source, len(source), expected, c.byref(revision))
        return code, revision.value

    def test_process_restart_retains_original_source_and_changed_command(self):
        source = '; 日本語の説明と改行を保持\n(define (stamp) (buffer/insert! "葛󠄀が\\n"))\n'.encode()
        self.assertEqual(self.apply(source).stdout, b'revision=1\n')
        self.assertEqual(self.cli('source').stdout, source)
        self.assertEqual(self.cli('run', 'stamp').stdout, '葛󠄀が\n'.encode())
        self.apply(b'(define (stamp) (buffer/insert! "updated"))')
        self.assertEqual(self.cli('run', 'stamp').stdout, b'updated')

    def test_restore_and_branch_keep_all_history(self):
        self.apply(b'(define (stamp) (buffer/insert! "one"))')
        self.apply(b'(define (stamp) (buffer/insert! "two"))')
        self.cli('select', 1)
        self.assertEqual(self.cli('run', 'stamp').stdout, b'one')
        self.apply(b'(define (stamp) (buffer/insert! "three"))')
        self.assertEqual(self.cli('history').stdout, b'3\n2\n1\n')
        self.cli('select', 2)
        self.assertEqual(self.cli('run', 'stamp').stdout, b'two')

    def test_bad_source_never_advances_head(self):
        self.apply(b'(define keep 17)')
        for source in [b'(define keep 18) (', b'(buffer/insert! "bad")', b'(define x missing)', b'\xff', b'(define x 1)\0', b'x' * 4097]:
            with self.subTest(source=source[:40]):
                self.apply(source, ok=False)
                self.assertEqual(self.cli('eval', 'keep').stdout, b'17')
                self.assertEqual(self.cli('history').stdout, b'1\n')

    def test_sqlite_abort_rolls_back_revision_and_head(self):
        self.apply(b'(define value 7)')
        with sqlite3.connect(self.path) as db:
            db.execute("CREATE TRIGGER fail_save BEFORE INSERT ON xy_source_revisions BEGIN SELECT RAISE(ABORT,'injected storage failure'); END")
        self.assertIn(b'injected storage failure', self.apply(b'(define value 9)', ok=False).stderr)
        self.assertEqual(self.cli('eval', 'value').stdout, b'7')
        self.assertEqual(self.cli('history').stdout, b'1\n')

    def test_concurrent_sessions_use_compare_and_swap(self):
        first, second = self.connect(), self.connect()
        self.assertEqual(self.save(first, b'(define x 1)', 0), (0, 1))
        self.assertEqual(self.save(second, b'(define x 2)', 0), (-1, 0))
        self.assertIn(b'another session', self.store.xy_workspace_error(second))
        self.assertEqual(self.save(second, b'(define x 2)', 1), (0, 2))
        self.assertEqual(self.store.xy_workspace_select(first, 1, 1), -1)
        self.assertEqual(self.cli('eval', 'x').stdout, b'2')

    def test_unknown_revision_and_undersized_reads_leave_head_unchanged(self):
        handle = self.connect()
        self.assertEqual(self.save(handle, b'(define x 3)', 0), (0, 1))
        out = c.create_string_buffer(4)
        revision = c.c_int64()
        self.assertEqual(self.store.xy_workspace_load(handle, 0, out, 4, c.byref(revision)), -1)
        self.assertEqual(revision.value, 0)
        self.assertEqual(self.store.xy_workspace_select(handle, 999, 1), -1)
        self.assertEqual(self.cli('eval', 'x').stdout, b'3')

    def test_busy_writer_preserves_active_revision(self):
        self.apply(b'(define value 4)')
        handle = self.connect()
        with sqlite3.connect(self.path) as db:
            db.execute('BEGIN IMMEDIATE')
            self.assertEqual(self.save(handle, b'(define value 9)', 1), (-1, 0))
            db.rollback()
        self.assertEqual(self.cli('eval', 'value').stdout, b'4')

    def test_empty_source_is_a_real_revision(self):
        self.apply(b'')
        self.assertEqual(self.cli('source').stdout, b'')
        self.assertEqual(self.cli('history').stdout, b'1\n')
        self.cli('run', 'stamp', ok=False)

    def test_broken_saved_source_falls_back_without_erasing_history(self):
        self.apply(b'(define value 1)')
        with sqlite3.connect(self.path) as db:
            db.execute('UPDATE xy_source_revisions SET source=? WHERE revision=1', (b'(',))
        self.assertIn(b'using built-in commands', self.cli('status').stdout)
        self.assertEqual(self.cli('source').stdout, b'(')
        self.assertEqual(self.cli('run', 'stamp').stdout, b'Hello from Scheme!\n')
        self.apply(b'(define repaired 42)')
        self.assertEqual(self.cli('eval', 'repaired').stdout, b'42')
        self.assertEqual(self.cli('history').stdout, b'2\n1\n')

    def test_safe_mode_skips_valid_user_commands(self):
        self.apply(b'(define (stamp) (buffer/insert! "custom"))')
        self.assertEqual(self.cli('run', 'stamp', '--safe').stdout, b'Hello from Scheme!\n')
        self.assertEqual(self.cli('run', 'stamp').stdout, b'custom')

    def test_foreign_database_rejected_without_schema_mutation(self):
        with sqlite3.connect(self.path) as db:
            db.execute('CREATE TABLE unrelated(value)')
            db.execute('INSERT INTO unrelated VALUES(42)')
        self.cli('status', ok=False)
        with sqlite3.connect(self.path) as db:
            self.assertEqual(db.execute('SELECT * FROM unrelated').fetchall(), [(42,)])
            self.assertEqual(db.execute('PRAGMA application_id').fetchone()[0], 0)
            self.assertEqual(db.execute('SELECT count(*) FROM sqlite_master WHERE name LIKE "xy_%"').fetchone()[0], 0)

    def init_real_fonts(self):
        directory = Path(os.environ.get('XY_FONT_DIR', Path.home() / 'repo/gjs/data/output/bunsen-build'))
        names = [f'Bunsen{family}{layer}-Regular.ttf' for family in ['Mincho', 'Gothic'] for layer in ['', 'Ext', 'PUP']]
        if not all((directory / name).is_file() for name in names):
            self.skipTest('External Bunsen font pack is unavailable')
        fds = [os.open(directory / name, os.O_RDONLY) for name in names]
        for fd in fds:
            self.addCleanup(os.close, fd)
        callback_type = c.CFUNCTYPE(c.c_uint32, c.c_void_p, c.c_uint32, c.c_void_p, c.c_uint32)
        def read(context, offset, output, length):
            data = os.pread(fds[context - 1], length, offset)
            c.memmove(output, data, len(data))
            return len(data)
        callback = callback_type(read)
        self._font_callback = callback
        class Descriptor(c.Structure):
            _fields_ = [('context', c.c_void_p), ('read', callback_type)]
        mincho = (Descriptor * 3)(*[Descriptor(i + 1, callback) for i in range(3)])
        gothic = (Descriptor * 3)(*[Descriptor(i + 4, callback) for i in range(3)])
        self.vm.xy_host_init.argtypes = [c.POINTER(Descriptor), c.c_uint32, c.POINTER(Descriptor), c.c_uint32]
        self.vm.xy_host_init.restype = c.c_bool
        self.assertTrue(self.vm.xy_host_init(mincho, 3, gothic, 3))

    def test_real_font_render_of_restored_command_and_source(self):
        self.init_real_fonts()
        # Same sequence as Mac startup: loading the workspace resets defaults.
        self.assertTrue(self.vm.xy_host_live_init())
        self.vm.xy_host_set_viewport(960, 540)
        output = c.create_string_buffer(256)
        source = b'(define (stamp) (buffer/insert! "xy live edit"))'
        self.assertTrue(self.vm.xy_host_live_prepare(source, len(source)))
        self.assertTrue(self.vm.xy_host_live_activate())
        self.assertGreater(self.vm.xy_host_live_run(b'stamp', 5, True, output, 256), 0)
        self.vm.xy_host_eval.argtypes = [c.c_char_p, c.c_uint32, c.c_void_p, c.c_uint32]
        expr = b"(view/set! #:direction 'vertical #:size 32)"
        self.assertGreater(self.vm.xy_host_eval(expr, len(expr), output, 256), 0)
        pixels = c.create_string_buffer(960 * 540 * 4)
        self.vm.xy_host_render_rgba8.argtypes = [c.c_void_p, c.c_uint32, c.c_uint32, c.c_uint32, c.c_uint8]
        self.assertGreater(self.vm.xy_host_render_rgba8(pixels, 960, 540, 960 * 4, 0), 0)
        raw = pixels.raw
        bg = raw[:4]
        self.assertGreater(sum(raw[i:i+4] != bg for i in range(0, len(raw), 4)), 100)
        self.vm.xy_host_source_enter.argtypes = [c.c_char_p, c.c_uint32]
        self.vm.xy_host_source_enter.restype = c.c_bool
        self.assertTrue(self.vm.xy_host_source_enter(source, len(source)))
        expr = b"(view/set! #:direction 'horizontal #:size 20)"
        self.assertGreater(self.vm.xy_host_eval(expr, len(expr), output, 256), 0)
        self.assertGreater(self.vm.xy_host_render_rgba8(pixels, 960, 540, 960 * 4, 0), 0)
        self.vm.xy_host_source_leave()

    def test_rgb565_rgba8_full_frame_parity_including_caret_and_padding(self):
        self.init_real_fonts()
        width, height = 1280, 720
        self.vm.xy_host_render_rgb565.argtypes = [c.c_void_p, c.c_uint32, c.c_uint32, c.c_uint32, c.c_uint8]
        self.vm.xy_host_render_rgba8.argtypes = [c.c_void_p, c.c_uint32, c.c_uint32, c.c_uint32, c.c_uint8]
        self.vm.xy_host_eval.argtypes = [c.c_char_p, c.c_uint32, c.c_void_p, c.c_uint32]
        self.vm.xy_host_insert_text.argtypes = [c.c_char_p, c.c_uint32]
        self.vm.xy_host_insert_text.restype = c.c_bool
        output = c.create_string_buffer(256)
        for direction, theme in [('horizontal', 0), ('vertical', 1)]:
            with self.subTest(direction=direction, theme=theme):
                self.assertTrue(self.vm.xy_host_live_init())
                self.vm.xy_host_set_viewport(width, height)
                source = '(define (stamp) (buffer/insert! "Hello, xy!"))\n日本語 ABC 0123'.encode()
                self.assertTrue(self.vm.xy_host_insert_text(source, len(source)))
                expr = f"(view/set! #:direction '{direction} #:size 25)".encode()
                self.assertGreater(self.vm.xy_host_eval(expr, len(expr), output, 256), 0)
                native_stride, rgba_stride = width * 2 + 8, width * 4 + 16
                native = c.create_string_buffer(b'\xa5' * (native_stride * height))
                rgba = c.create_string_buffer(b'\xa5' * (rgba_stride * height))
                self.assertGreater(self.vm.xy_host_render_rgb565(native, width, height, native_stride, theme), 0)
                self.assertGreater(self.vm.xy_host_render_rgba8(rgba, width, height, rgba_stride, theme), 0)
                native_bytes, rgba_bytes = native.raw, rgba.raw
                for row in range(height):
                    expected = bytearray()
                    data = native_bytes[row * native_stride:(row + 1) * native_stride]
                    for x in range(width):
                        color = int.from_bytes(data[x*2:x*2+2], 'little')
                        r, g, b = (color >> 11) & 31, (color >> 5) & 63, color & 31
                        expected.extend(((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2), 255))
                    actual = rgba_bytes[row * rgba_stride:(row + 1) * rgba_stride]
                    self.assertEqual(actual[:width * 4], expected, f'row {row}')
                    self.assertEqual(actual[width * 4:], b'\xa5' * 16)
                    self.assertEqual(data[width * 2:], b'\xa5' * 8)
                evidence_dir = os.environ.get('XY_RENDER_EVIDENCE_DIR')
                if evidence_dir:
                    directory = Path(evidence_dir)
                    directory.mkdir(parents=True, exist_ok=True)
                    visible = b''.join(rgba_bytes[y * rgba_stride:y * rgba_stride + width * 4] for y in range(height))
                    native_visible = b''.join(native_bytes[y * native_stride:y * native_stride + width * 2] for y in range(height))
                    def chunk(kind, data):
                        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
                    scanlines = b''.join(b'\0' + visible[y * width * 4:(y + 1) * width * 4] for y in range(height))
                    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(scanlines)) + chunk(b'IEND', b'')
                    stem = f'{direction}-{theme}'
                    (directory / f'{stem}.png').write_bytes(png)
                    (directory / f'{stem}.json').write_text(json.dumps({'width': width, 'height': height, 'rgb565_sha256': hashlib.sha256(native_visible).hexdigest(), 'rgba_sha256': hashlib.sha256(visible).hexdigest(), 'pixels_compared': width * height, 'mismatched_pixels': 0, 'source': source.decode()}, indent=2, ensure_ascii=False) + '\n')
                unchanged = rgba.raw
                self.assertLess(self.vm.xy_host_render_rgba8(rgba, width, height, width * 4 - 1, theme), 0)
                self.assertEqual(rgba.raw, unchanged)
        self.assertTrue(self.vm.xy_host_live_init())
        self.vm.xy_host_set_viewport(width, height)
        self.assertEqual(self.vm.xy_host_render_rgba8(rgba, width, height, rgba_stride, 0), 0)

    def test_same_process_vm_swap_and_failed_editor_effects_are_atomic(self):
        self.assertTrue(self.vm.xy_host_live_init())
        output = c.create_string_buffer(16384)
        def run(source, named=False):
            return self.vm.xy_host_live_run(source, len(source), named, output, len(output))
        def install(source):
            self.assertTrue(self.vm.xy_host_live_prepare(source, len(source)))
            self.assertTrue(self.vm.xy_host_live_activate())
        install(b'(define value 7) (define (stamp) (buffer/insert! "old"))')
        self.assertGreaterEqual(run(b'stamp', True), 0)
        self.assertLess(run(b'(set! value 99) (buffer/insert! "bad") missing'), 0)
        self.assertEqual(run(b'value'), 1)
        self.assertEqual(output.raw[:1], b'7')
        install(b'(define (stamp) (buffer/insert! "new"))')
        self.assertGreaterEqual(run(b'stamp', True), 0)
        n = self.vm.xy_host_buffer_copy(output, len(output))
        self.assertEqual(output.raw[:n], b'oldnew')
        self.assertFalse(self.vm.xy_host_live_prepare(b'(buffer/insert! "bad")', 22))
        self.assertFalse(self.vm.xy_host_live_activate())
        self.assertGreaterEqual(run(b'stamp', True), 0)


if __name__ == '__main__':
    unittest.main()
