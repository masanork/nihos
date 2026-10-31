"""Exercise the exact native SQLite initialization/allocator configuration on host."""
import ctypes as c
import os
from pathlib import Path
import platform
import shlex
import subprocess
import tempfile
import unittest
from sqld_native_build import DEFINES, ROOT

class NativeAllocatorTests(unittest.TestCase):
    def test_other_os_starts_without_default_vfs_and_never_falls_back_to_malloc(self):
        subprocess.run(['sh', str(ROOT/'tools/bootstrap-sqlite.sh')], check=True, stdout=subprocess.DEVNULL)
        with tempfile.TemporaryDirectory(prefix='sqld-allocator-') as directory:
            output=Path(directory)/'allocator.so'
            source=ROOT/'build/sqlite/sqlite-amalgamation-3540100'
            shared='-dynamiclib' if platform.system()=='Darwin' else '-shared'
            subprocess.run([*shlex.split(os.environ.get('CC','cc')),'-O2','-fPIC',shared,*['-D'+v for v in DEFINES],'-I'+str(source),str(source/'sqlite3.c'),str(ROOT/'src/services/sqld_native_allocator.c'),'-lm','-o',str(output)],check=True)
            lib=c.CDLL(str(output));lib.nih_sqld_native_allocator.argtypes=[c.c_void_p,c.c_uint32]
            lib.sqlite3_malloc.argtypes=[c.c_int];lib.sqlite3_malloc.restype=c.c_void_p
            lib.sqlite3_free.argtypes=[c.c_void_p];lib.sqlite3_memory_used.restype=c.c_int64
            backing=c.create_string_buffer(1048576+63);base=(c.addressof(backing)+63)&~63
            self.assertEqual(lib.nih_sqld_native_allocator(base,1048576),0)
            self.addCleanup(lambda: (lib.sqlite3_shutdown(), backing))
            pointer=lib.sqlite3_malloc(262144)
            self.assertTrue(pointer is not None and base<=pointer<base+1048576)
            self.assertIsNone(lib.sqlite3_malloc(2097152))
            lib.sqlite3_free(pointer)
            self.assertEqual(lib.sqlite3_memory_used(),0)
            self.assertEqual(lib.sqlite3_initialize(),0)
