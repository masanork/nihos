import copy
import importlib.util
from pathlib import Path
import unittest
import native_checks_test as FIXTURES
NATIVE = FIXTURES.MODULE

SPEC = importlib.util.spec_from_file_location('storage_oracle', Path(__file__).with_name('check-storage-oracle.py'))
ORACLE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ORACLE)


def record():
    return dict(zip(NATIVE.STORAGE_FIELDS, (2, 0, 2, 4096, 3858432, 4, 3, 1, 0x40e9d8c6, 10752, 0x883551bf, 0x33445ceb, 165, 0)))


def line(marker, values):
    return marker + ''.join(f' {name}={value:08x}' for name, value in values.items())


def fixture():
    tail = FIXTURES.HardwareQualificationTests().sdmmc_log().split('\nNIHOS_NATIVE_SDMMC_MODE', 1)[1]
    log = FIXTURES.sqlite_log() + '\nNIHOS_NATIVE_SDMMC_MODE' + tail
    log += '\n' + line('NIHOS_NATIVE_STORAGE', record())
    log += '\nNIHOS_NATIVE_STORAGE_STACK low=4ff60010 high=4ff62000 painted_to=4ff61c00 used=00001000 confirmed=00000001'
    image = {**FIXTURES.complete_image(), 'memory': {'profile': 'device'}, 'sqlite': {
        'pool_quotas': [24, 12, 64, 64, 64, 4, 8, 12, 8, 1], 'littlefs': {'read_only': True},
        'text_start': '0x40020000', 'text_end': '0x40021000', 'rodata_start': '0x40021000', 'rodata_end': '0x40022000',
        'functions': {'nih_sqlite_session_open': {'start': '0x40020000', 'end': '0x40020100'}}}}
    log = log.replace('4ff40000', '4ff18000').replace('4ff44000', '4ff1c000').replace('4ff48000', '4ff20000')
    image['heap'] = {'start': '0x4ff18000', 'end': '0x4ff20000', 'bytes': 32768}
    return log, image


class StorageChecks(unittest.TestCase):
    def test_complete_physical_storage_requires_image_and_stack_binding(self):
        log, image = fixture()
        result = NATIVE.check(log, 'sqlite', 32 << 20, image, 'physical-device', require_storage=True)
        self.assertEqual(result['storage']['file_bytes'], 10752)
        self.assertEqual(result['storage_stack']['used'], 4096)
        for changed in (log.replace('confirmed=00000001\n', 'confirmed=00000000\n'),
                        log.replace('used=00001000', 'used=00002000'),
                        log.replace('NIHOS_NATIVE_STORAGE_STACK low=', 'MISSING_STACK low='),
                        log + '\n' + line('NIHOS_NATIVE_STORAGE', record())):
            with self.assertRaises(ValueError):
                NATIVE.check(changed, 'sqlite', 32 << 20, image, 'physical-device', require_storage=True)
        image['sqlite'].pop('littlefs')
        with self.assertRaisesRegex(ValueError, 'littlefs image'):
            NATIVE.check(log, 'sqlite', 32 << 20, image, 'physical-device')

    def test_partial_reads_wrong_geometry_writes_and_failed_mounts_are_rejected(self):
        for key, value in (('status', 3), ('passes', 1), ('error_code', 5), ('block_size', 512),
                           ('entries', 129), ('files', 2), ('reads', 0), ('reads', 8193),
                           ('denied_writes', 1), ('file_bytes', 0), ('file_bytes', 65537)):
            with self.subTest(key=key), self.assertRaises(ValueError):
                NATIVE.check_storage({**record(), key: value}, 30867456)

    def test_directory_only_is_distinguished_from_a_file_read(self):
        r = {**record(), 'status': 1, 'file_bytes': 0, 'file_crc': 0, 'file_name_digest': 0}
        NATIVE.check_storage(r, 30867456)
        with self.assertRaises(ValueError):
            NATIVE.check_storage({**r, 'file_crc': 1}, 30867456)

    def test_idf_comparison_rejects_partial_duplicate_and_different_results(self):
        log, image = fixture()
        native = NATIVE.check(log, 'sqlite', 32 << 20, image, 'physical-device')
        reference = 'NIHOS_SDMMC_IDF_ORACLE_CARD sectors=30867456\n' + line('NIHOS_STORAGE_IDF', record()) + '\nNIHOS_SDMMC_IDF_ORACLE_PASS reads=1032 writes=0\n'
        self.assertTrue(ORACLE.compare(reference, native)['passed'])
        for changed in (reference.replace('file_crc=883551bf', 'file_crc=883551be'),
                        reference.replace('file_name_digest=33445ceb', 'file_name_digest=33445cea'),
                        reference.replace('directory_digest=40e9d8c6', 'directory_digest=40e9d8c7'),
                        reference + line('NIHOS_STORAGE_IDF', record()), reference.replace('ORACLE_PASS', 'MISSING_PASS')):
            with self.assertRaises(ValueError):
                ORACLE.compare(changed, native)
        emulator = copy.deepcopy(native)
        emulator['evidence'] = 'emulator'
        with self.assertRaises(ValueError):
            ORACLE.compare(reference, emulator)
