#!/usr/bin/env python3
"""Disposable 4 MiB SQLite -> 32 MiB copy -> dictionary ABI integration."""
import hashlib
import os
from pathlib import Path
import sqlite3
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    host = ROOT / 'build/sqld/sqld-host'
    if not host.is_file():
        subprocess.run(['sh', 'tools/build-sqld-host.sh'], cwd=ROOT, check=True)
    zig = subprocess.check_output([str(ROOT / 'tools/bootstrap-zig.sh')], text=True).strip()
    with tempfile.TemporaryDirectory(prefix='nihos-capacity-abi-') as tmp:
        tmp = Path(tmp)
        legacy = tmp / 'legacy.img'
        database = tmp / 'migrated.db'
        abi_object = tmp / 'store32.o'
        subprocess.run([zig, 'build-obj', '-O', 'ReleaseSafe', '-fPIC', '-fcompiler-rt', 'src/storage/store_abi_32m_probe.zig', '-femit-bin=' + str(abi_object)], cwd=ROOT, check=True)
        sql = "2 0 0 0 CREATE TABLE notes(id INTEGER PRIMARY KEY, body TEXT)\n2 0 0 0 INSERT INTO notes VALUES(1, '日本語')\n1 0 0 0 SELECT * FROM notes\n"
        subprocess.run([str(host), '--create', str(legacy)], input=sql, text=True, check=True, capture_output=True)
        before = hashlib.sha256(legacy.read_bytes()).digest()
        supplied = os.environ.get('NIHOS_NFST_PATH')
        if supplied:
            dictionary = Path(supplied).resolve(strict=True)
        else:
            # Extend the small fixture's arena with unreferenced zero bytes.
            # This tests capacity, not large-dictionary conversion quality.
            payload = bytearray((ROOT / 'src/xy/fixtures/jisyo_s_nfst.bin').read_bytes())
            extra = 5_129_285 - len(payload)
            struct.pack_into('<I', payload, 32, struct.unpack_from('<I', payload, 32)[0] + extra)
            dictionary = tmp / 'padded.nfst'
            dictionary.write_bytes(payload + bytes(extra))
        env = dict(os.environ, NIHOS_LEGACY_IMAGE=str(legacy), NIHOS_NFST_PATH=str(dictionary), NIHOS_MIGRATED_DB=str(database))
        subprocess.run([zig, 'test', '-O', 'ReleaseSafe', '-lc', 'src/capacity_copy_large_host_test.zig', str(abi_object), '--test-filter', 'larger host store'], cwd=ROOT, env=env, check=True)
        if hashlib.sha256(legacy.read_bytes()).digest() != before:
            raise AssertionError('source image changed')
        conn = sqlite3.connect(f'file:{database}?mode=ro', uri=True)
        try:
            if conn.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
                raise AssertionError('migrated SQLite integrity check failed')
            if conn.execute('SELECT id, body FROM notes').fetchall() != [(1, '日本語')]:
                raise AssertionError('migrated SQLite row differs')
        finally:
            conn.close()
        print('capacity ABI copy: source unchanged, SQLite integrity ok, NFST lookup ok; host only')


if __name__ == '__main__':
    main()
