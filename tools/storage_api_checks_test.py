import copy
import unittest
import storage_checks_test as BASE
NATIVE = BASE.NATIVE


def api_record():
    return dict(zip(NATIVE.STORAGE_API_FIELDS, (1,4,4,2,8,46,8192,3500,1)))


def fixture():
    log, image = BASE.fixture()
    image['sqlite']['littlefs']['api_version'] = 1
    log += '\n' + BASE.line('NIHOS_NATIVE_STORAGE_API', api_record())
    log += '\nNIHOS_NATIVE_STORAGE_WORKSPACE start=48001000 bytes=00002000 cleared=00000001'
    return log, image


class StorageAPIChecks(unittest.TestCase):
    def test_api_and_reserved_psram_are_bound_to_the_image(self):
        log, image = fixture()
        result = NATIVE.check(log, 'sqlite', 32 << 20, image, 'physical-device')
        self.assertEqual(result['storage_api']['cancelled'], 2)
        self.assertEqual(result['storage_workspace']['start'], 0x48001000)
        for changed in (log.replace('NIHOS_NATIVE_STORAGE_API ', 'MISSING_API '),
                        log.replace('start=48001000', 'start=48030000'),
                        log.replace('bytes=00002000', 'bytes=00004000'),
                        log.replace('cancelled=00000002', 'cancelled=00000001'),
                        log.replace('rejected=00000008', 'rejected=00000007'),
                        log.replace('read_calls=0000002e', 'read_calls=0000002d'),
                        log.replace('used_bytes=00000dac', 'used_bytes=00004000')):
            with self.assertRaises(ValueError):
                NATIVE.check(changed, 'sqlite', 32 << 20, image, 'physical-device')

    def test_workspace_clearing_and_all_handle_closes_are_required(self):
        for key,value in (('closes',3),('cleared',0),('opens',3),('workspace_bytes',4096),('used_bytes',0)):
            with self.assertRaises(ValueError):
                NATIVE.check_storage_api({**api_record(),key:value},BASE.record())

    def test_reference_requires_matching_api_evidence(self):
        log, image = fixture()
        native = NATIVE.check(log,'sqlite',32 << 20,image,'physical-device')
        ref = 'NIHOS_SDMMC_IDF_ORACLE_CARD sectors=30867456\n' + BASE.line('NIHOS_STORAGE_IDF',BASE.record())
        ref += '\n' + BASE.line('NIHOS_STORAGE_API_IDF',api_record()) + '\nNIHOS_SDMMC_IDF_ORACLE_PASS reads=1032 writes=0\n'
        self.assertTrue(BASE.ORACLE.compare(ref,native)['passed'])
        for changed in (ref.replace('NIHOS_STORAGE_API_IDF ', 'MISSING_API '),ref.replace('cleared=00000001','cleared=00000000')):
            with self.assertRaises(ValueError):
                BASE.ORACLE.compare(changed,native)
        old = copy.deepcopy(native); old['storage_api'] = None
        with self.assertRaises(ValueError):
            BASE.ORACLE.compare(ref,old)
