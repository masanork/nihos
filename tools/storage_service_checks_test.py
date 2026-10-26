import unittest
import storage_api_checks_test as BASE
NATIVE = BASE.NATIVE


def record():
    return dict(zip(NATIVE.SERVICE_FIELDS, (1,36,38,1,5,10752,0x883551bf,0x01010003,1,1,1,3184,1360,100,100000,1,1,1)))


def fixture():
    log, image = BASE.fixture()
    image['sqlite']['littlefs']['service'] = {'version':1}
    for old,new in [('opened=00000007','opened=00000008'),('closed=00000006','closed=00000007'),
                    ('completed=00000006','completed=00000007'),('reuses=00000003','reuses=00000004'),
                    ('stale=00000003','stale=00000004')]:
        log=log.replace(old,new)
    log += '\n' + BASE.BASE.line('NIHOS_NATIVE_STORAGE_SERVICE',record())
    return log,image


class StorageServiceChecks(unittest.TestCase):
    def test_service_requires_bound_identity_queues_cleanup_and_worker_stacks(self):
        log,image=fixture()
        result=NATIVE.check(log,'sqlite',32<<20,image,'physical-device')
        self.assertEqual(result['storage_service']['responses'],38)
        for key,value in [('released',0),('exit_seen',0),('owner',3),('owner_stack',3920),('client_stack',4096),
                           ('crc',0),('requests',38),('responses',37),('queue_full',0),('rejected',4),
                           ('peer_polls',0),('fs_cleared',0),('ipc_cleared',0),('clock_ok',0),('elapsed_us',0)]:
            changed=log.replace(BASE.BASE.line('NIHOS_NATIVE_STORAGE_SERVICE',record()),BASE.BASE.line('NIHOS_NATIVE_STORAGE_SERVICE',{**record(),key:value}))
            with self.subTest(key=key),self.assertRaises(ValueError):
                NATIVE.check(changed,'sqlite',32<<20,image,'physical-device')

    def test_service_image_cannot_accept_missing_record_or_old_resource_ledger(self):
        log,image=fixture()
        for changed in [log.replace('NIHOS_NATIVE_STORAGE_SERVICE ','MISSING_SERVICE '),
                        log.replace('stale=00000004','stale=00000003'),
                        log.replace('completed=00000007','completed=00000006'),
                        log+'\n'+BASE.BASE.line('NIHOS_NATIVE_STORAGE_SERVICE',record())]:
            with self.assertRaises(ValueError):
                NATIVE.check(changed,'sqlite',32<<20,image,'physical-device')
