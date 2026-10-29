import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

spec = importlib.util.spec_from_file_location('fatfs_fetch', Path(__file__).with_name('bootstrap-fatfs.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def sha(data): return hashlib.sha256(data).hexdigest()


class FallbackTests(unittest.TestCase):
    def test_transport_failure_uses_verified_identical_fallback(self):
        original = {'ff.h': b'header\r\n', 'ffunicode.c': b'unicode\r\n', 'diskio.h': b'disk\r\n'}
        patched = b'patched\n'
        hashes = {name: sha(data) for name, data in original.items()}
        def fetch(url):
            if url == module.MIRROR_PATCHED: return b'patched\r\n'
            return original[url.rsplit('/', 1)[1]].replace(b'\r\n', b'\n')
        with tempfile.TemporaryDirectory() as path, patch.object(module, 'official', side_effect=urllib.error.URLError('offline')), \
                patch.object(module, 'fetch', side_effect=fetch), patch.object(module, 'SOURCE_HASHES', hashes), \
                patch.object(module, 'PATCHED_HASH', sha(patched)):
            source = module.bootstrap(path)
            self.assertEqual((source / 'ff.c').read_bytes(), patched)
            for name, data in original.items(): self.assertEqual((source / name).read_bytes(), data)

    def test_verified_cache_is_reused_and_corruption_is_not(self):
        original = {'ff.c': b'patched', 'ff.h': b'header', 'ffunicode.c': b'unicode', 'diskio.h': b'disk'}
        hashes = {name: sha(data) for name, data in original.items() if name != 'ff.c'}
        with tempfile.TemporaryDirectory() as path, patch.object(module, 'SOURCE_HASHES', hashes), \
                patch.object(module, 'PATCHED_HASH', sha(original['ff.c'])), \
                patch.object(module, 'official', side_effect=RuntimeError('rebuild required')) as official:
            source = Path(path) / 'source'
            source.mkdir()
            for name, data in original.items(): (source / name).write_bytes(data)
            self.assertEqual(module.bootstrap(path), source)
            official.assert_not_called()
            (source / 'ff.h').write_bytes(b'corrupt')
            with self.assertRaisesRegex(RuntimeError, 'rebuild required'): module.bootstrap(path)
            official.assert_called_once()

    def test_bad_mirror_fails_closed_and_does_not_publish(self):
        with tempfile.TemporaryDirectory() as path, patch.object(module, 'official', side_effect=urllib.error.URLError('offline')), \
                patch.object(module, 'fetch', return_value=b'bad'):
            with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'): module.bootstrap(path)
            self.assertFalse((Path(path) / 'source').exists())

    def test_official_integrity_error_does_not_use_fallback(self):
        with tempfile.TemporaryDirectory() as path, patch.object(module, 'official', side_effect=RuntimeError('checksum mismatch')), \
                patch.object(module, 'fallback') as fallback:
            with self.assertRaisesRegex(RuntimeError, 'checksum mismatch'): module.bootstrap(path)
            fallback.assert_not_called()
