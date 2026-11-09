#!/usr/bin/env python3
"""Separate host-media geometry and dictionary stream ABI integration."""
import ctypes as c
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PAGE = 4096
DICT_SIZE = 5_129_285
Read = c.CFUNCTYPE(c.c_int, c.c_void_p, c.c_uint64, c.c_void_p, c.c_size_t)
Sync = c.CFUNCTYPE(c.c_int, c.c_void_p)


class Device(c.Structure):
    _fields_ = [('context', c.c_void_p), ('read', Read), ('write', Read), ('sync', Sync)]


def load(path):
    lib = c.CDLL(str(path))
    lib.nih_store_size.restype = c.c_size_t
    lib.nih_store_mount.argtypes = [c.c_void_p, c.c_size_t, c.POINTER(Device), c.c_int]
    lib.nih_store_dictionary_begin.argtypes = [c.c_void_p, c.c_uint64, c.POINTER(c.c_uint64)]
    lib.nih_store_dictionary_write.argtypes = [c.c_void_p, c.c_uint64, c.c_void_p, c.c_size_t]
    lib.nih_store_dictionary_finish.argtypes = [c.c_void_p, c.c_uint64]
    lib.nih_store_dictionary_abort.argtypes = [c.c_void_p, c.c_uint64]
    lib.nih_store_sync.argtypes = [c.c_void_p]
    lib.nih_store_pin_object.argtypes = [c.c_void_p, c.c_uint32, c.POINTER(c.c_uint32), c.POINTER(c.c_uint64)]
    lib.nih_store_read_object.argtypes = [c.c_void_p, c.c_uint32, c.c_uint64, c.c_void_p, c.c_size_t]
    lib.nih_store_release.argtypes = [c.c_void_p, c.c_uint32]
    lib.nih_store_verify.argtypes = [c.c_void_p, c.c_uint32]
    return lib


class Medium:
    def __init__(self, lib, size):
        self.lib = lib
        self.stable = bytearray(b'\xff' * size)
        self.cache = self.stable.copy()
        self.buffer = (c.c_ubyte * size).from_buffer(self.cache)
        self.fail_sync_at = None
        self.sync_calls = 0
        self.flush_on_failure = False
        def read(_, offset, out, count):
            if offset > size or count > size - offset: return -1
            c.memmove(out, c.addressof(self.buffer) + offset, count)
            return 0
        def write(_, offset, data, count):
            if offset > size or count > size - offset: return -1
            c.memmove(c.addressof(self.buffer) + offset, data, count)
            return 0
        def sync(_):
            self.sync_calls += 1
            failing = self.sync_calls == self.fail_sync_at
            if not failing or self.flush_on_failure:
                self.stable[:] = self.cache
            return -1 if failing else 0
        self.callbacks = (Read(read), Read(write), Sync(sync))
        self.device = Device(None, *self.callbacks)
        self.open(True)

    def open(self, create):
        self.state = c.create_string_buffer(self.lib.nih_store_size())
        rc = self.lib.nih_store_mount(self.state, len(self.state), c.byref(self.device), int(create))
        if rc != 0: raise AssertionError(('mount', rc))

    def recover(self):
        self.cache[:] = self.stable
        self.fail_sync_at = None
        self.open(False)

    def begin(self, size):
        token = c.c_uint64()
        rc = self.lib.nih_store_dictionary_begin(self.state, size, c.byref(token))
        return rc, token.value

    def write(self, token, data):
        offset = 0
        while offset < len(data):
            chunk = data[offset:offset + PAGE]
            source = c.create_string_buffer(chunk)
            count = self.lib.nih_store_dictionary_write(self.state, token, source, len(chunk))
            if count <= 0: raise AssertionError(('write', count, offset))
            offset += count

    def import_bytes(self, data):
        rc, token = self.begin(len(data))
        if rc != 0: raise AssertionError(('begin', rc))
        self.write(token, data)
        if self.lib.nih_store_dictionary_finish(self.state, token) != 0: raise AssertionError('finish')
        return token

    def read_pinned(self):
        token, length = c.c_uint32(), c.c_uint64()
        rc = self.lib.nih_store_pin_object(self.state, 64, c.byref(token), c.byref(length))
        if rc != 0: raise AssertionError(('pin', rc))
        output = bytearray()
        while len(output) < length.value:
            count = min(PAGE, length.value - len(output))
            dest = c.create_string_buffer(count)
            got = self.lib.nih_store_read_object(self.state, token.value, len(output), dest, count)
            if got != count: raise AssertionError(('read', got, count))
            output.extend(dest.raw)
        if self.lib.nih_store_release(self.state, token.value) != 0: raise AssertionError('release')
        return bytes(output)


class DictionaryStoreAbiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix='nihos-dictionary-abi-')
        zig = subprocess.check_output([str(ROOT / 'tools/bootstrap-zig.sh')], text=True).strip()
        rejected = subprocess.run([zig, 'build-obj', '-target', 'riscv32-freestanding-none', str(ROOT / 'src/storage/store_abi_32m_probe.zig'), '-fno-emit-bin'], cwd=ROOT, capture_output=True, text=True)
        if rejected.returncode == 0 or 'host-only' not in rejected.stderr:
            raise AssertionError('32 MiB probe must reject freestanding builds')
        ext = 'dylib' if sys.platform == 'darwin' else 'so'
        cls.libs = {}
        for name, source in [('small', 'store_abi.zig'), ('large', 'store_abi_32m_probe.zig')]:
            output = Path(cls.tmp.name) / ('lib' + name + '.' + ext)
            subprocess.run([zig, 'build-lib', '-dynamic', '-O', 'ReleaseSafe', '-fPIC', str(ROOT / 'src/storage' / source), '-femit-bin=' + str(output)], check=True, cwd=ROOT)
            cls.libs[name] = load(output)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_large_stream_remount_and_exact_bytes(self):
        fixture = os.environ.get('NIHOS_NFST_PATH')
        payload = Path(fixture).read_bytes() if fixture else (bytes(range(256)) * ((DICT_SIZE + 255) // 256))[:DICT_SIZE]
        if fixture:
            self.assertEqual(payload[:4], b'NFST')
        self.assertGreater(len(payload), 4 * 1024 * 1024)
        medium = Medium(self.libs['large'], 32 * 1024 * 1024)
        token = medium.import_bytes(payload)
        self.assertEqual(medium.lib.nih_store_dictionary_write(medium.state, token, b'x', 1), -22)
        self.assertEqual(medium.lib.nih_store_sync(medium.state), 0)
        medium.recover()
        self.assertEqual(medium.lib.nih_store_verify(medium.state, 64), 0)
        self.assertEqual(hashlib.sha256(medium.read_pinned()).digest(), hashlib.sha256(payload).digest())

    def test_small_geometry_rejects_large_import(self):
        medium = Medium(self.libs['small'], 4 * 1024 * 1024)
        rc, token = medium.begin(DICT_SIZE)
        self.assertNotEqual(rc, 0)
        self.assertEqual(token, 0)
        self.assertEqual(medium.lib.nih_store_sync(medium.state), 0)

    def test_wrong_geometry_does_not_open_or_write(self):
        medium = Medium(self.libs['large'], 32 * 1024 * 1024)
        medium.import_bytes(b'old')
        self.assertEqual(medium.lib.nih_store_sync(medium.state), 0)
        before = hashlib.sha256(medium.stable).digest()
        wrong = c.create_string_buffer(self.libs['small'].nih_store_size())
        self.assertNotEqual(self.libs['small'].nih_store_mount(wrong, len(wrong), c.byref(medium.device), 0), 0)
        self.assertEqual(hashlib.sha256(medium.stable).digest(), before)
        self.assertEqual(hashlib.sha256(medium.cache).digest(), before)

    def test_incomplete_abort_preserves_committed_dictionary(self):
        medium = Medium(self.libs['large'], 32 * 1024 * 1024)
        medium.import_bytes(b'old')
        self.assertEqual(medium.lib.nih_store_sync(medium.state), 0)
        rc, token = medium.begin(8193)
        self.assertEqual(rc, 0)
        medium.write(token, b'new')
        self.assertEqual(medium.lib.nih_store_dictionary_finish(medium.state, token), -16)
        self.assertEqual(medium.lib.nih_store_sync(medium.state), -16)
        self.assertEqual(medium.lib.nih_store_dictionary_abort(medium.state, token + 1), -22)
        self.assertEqual(medium.lib.nih_store_dictionary_abort(medium.state, token), 0)
        medium.recover()
        self.assertEqual(medium.read_pinned(), b'old')

    def test_failed_sync_requires_recovery(self):
        for stage, flush in ((1, False), (1, True), (2, False), (2, True)):
            medium = Medium(self.libs['large'], 32 * 1024 * 1024)
            medium.import_bytes(b'old')
            self.assertEqual(medium.lib.nih_store_sync(medium.state), 0)
            medium.import_bytes(b'new')
            medium.sync_calls = 0
            medium.fail_sync_at = stage
            medium.flush_on_failure = flush
            self.assertNotEqual(medium.lib.nih_store_sync(medium.state), 0)
            medium.recover()
            self.assertEqual(medium.read_pinned(), b'new' if stage == 2 and flush else b'old')

    def test_replacement_keeps_pinned_original(self):
        medium = Medium(self.libs['large'], 32 * 1024 * 1024)
        medium.import_bytes(b'old')
        self.assertEqual(medium.lib.nih_store_sync(medium.state), 0)
        pin, size = c.c_uint32(), c.c_uint64()
        self.assertEqual(medium.lib.nih_store_pin_object(medium.state, 64, c.byref(pin), c.byref(size)), 0)
        medium.import_bytes(b'new')
        self.assertEqual(medium.lib.nih_store_sync(medium.state), 0)
        original = c.create_string_buffer(3)
        self.assertEqual(medium.lib.nih_store_read_object(medium.state, pin.value, 0, original, 3), 3)
        self.assertEqual(original.raw, b'old')
        self.assertEqual(medium.lib.nih_store_release(medium.state, pin.value), 0)
        self.assertEqual(medium.read_pinned(), b'new')


if __name__ == '__main__':
    unittest.main()
