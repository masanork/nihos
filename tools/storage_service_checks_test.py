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


class StorageCancellationChecks(unittest.TestCase):
    def test_forced_exit_requires_drained_queues_and_completed_inflight_read(self):
        log,image=fixture()
        image['sqlite']['littlefs']['service']['version']=2
        old=BASE.BASE.line('NIHOS_NATIVE_STORAGE_SERVICE',record())
        fields={**record(),'requests':38,'forced_exit':1,'inflight_completed':1,'discarded_requests':2,'discarded_responses':2}
        log=log.replace(old,BASE.BASE.line('NIHOS_NATIVE_STORAGE_SERVICE',fields))
        # Only CPU1's second forced termination changes the ledger.
        lines=log.splitlines()
        lines=[line.replace('forced=00000001','forced=00000002') if line.startswith('NIHOS_NATIVE_RESOURCES hart=00000001') else line for line in lines]
        log='\n'.join(lines)
        self.assertEqual(NATIVE.check(log,'sqlite',32<<20,image,'physical-device')['storage_service']['discarded_requests'],2)
        for key in NATIVE.CANCEL_FIELDS:
            changed=log.replace(BASE.BASE.line('NIHOS_NATIVE_STORAGE_SERVICE',fields),BASE.BASE.line('NIHOS_NATIVE_STORAGE_SERVICE',{**fields,key:0}))
            with self.subTest(key=key),self.assertRaises(ValueError):
                NATIVE.check(changed,'sqlite',32<<20,image,'physical-device')
        with self.assertRaises(ValueError):
            NATIVE.check(log.replace('forced=00000002','forced=00000001'),'sqlite',32<<20,image,'physical-device')


class StorageRebindChecks(unittest.TestCase):
    def test_replacement_requires_generation_stale_rejections_second_read_and_second_task_ledger(self):
        log,image=fixture()
        image['sqlite']['littlefs']['service']['version']=3
        fields={**record(),'requests':62,'responses':63,'rejected':8,'forced_exit':1,'inflight_completed':1,'discarded_requests':2,'discarded_responses':2,
                'rebound':1,'replacement_owner':0x01010004,'old_epoch_rejected':1,'old_reply_rejected':1,'old_handle_rejected':2,'old_exit_rejected':1,'replacement_exit':1,'replacement_bytes':10752,'replacement_crc':0x883551bf}
        log=log.replace(BASE.BASE.line('NIHOS_NATIVE_STORAGE_SERVICE',record()),BASE.BASE.line('NIHOS_NATIVE_STORAGE_SERVICE',fields))
        changes=[('opened=00000008','opened=00000009'),('closed=00000007','closed=00000008'),('completed=00000007','completed=00000008'),
                 ('reuses=00000004','reuses=00000005'),('stale=00000004','stale=00000005'),('forced=00000001','forced=00000002')]
        lines=log.splitlines()
        for i,line in enumerate(lines):
            if line.startswith('NIHOS_NATIVE_RESOURCES hart=00000001'):
                for old,new in changes:line=line.replace(old,new)
                lines[i]=line
        log='\n'.join(lines)
        self.assertEqual(NATIVE.check(log,'sqlite',32<<20,image,'physical-device')['storage_service']['replacement_owner'],0x01010004)
        for key in NATIVE.REBIND_FIELDS:
            changed=log.replace(BASE.BASE.line('NIHOS_NATIVE_STORAGE_SERVICE',fields),BASE.BASE.line('NIHOS_NATIVE_STORAGE_SERVICE',{**fields,key:0}))
            with self.subTest(key=key),self.assertRaises(ValueError):
                NATIVE.check(changed,'sqlite',32<<20,image,'physical-device')
        with self.assertRaises(ValueError):
            NATIVE.check(log.replace('stale=00000005','stale=00000004'),'sqlite',32<<20,image,'physical-device')


class SdBootPlacementChecks(unittest.TestCase):
    def test_sd_flash_pc_requires_matching_image_extent_completion_and_unique_record(self):
        log,image=fixture()
        image['flash_boot']['end']='0x40003920'
        image['flash_boot']['functions']['sdmmc']={'name':'sdmmc_probe.run','start':'0x40001120','end':'0x40003920'}
        log=log.replace('NIHOS_NATIVE_BOOT_CODE start=40000120 end=40001120', 'NIHOS_NATIVE_BOOT_CODE start=40000120 end=40003920')
        fields={'start':0x40001120,'end':0x40003920,'pc':0x40001124,'completed':1}
        marker=BASE.BASE.line('NIHOS_NATIVE_SDMMC_CODE',fields)
        log+='\n'+marker
        self.assertEqual(NATIVE.check(log,'sqlite',32<<20,image,'physical-device')['sdmmc_code']['pc'],0x40001124)
        for key,value in [('start',0x40001122),('end',0x40003922),('pc',0x4ff00000),('pc',0x40001125),('completed',0)]:
            changed=log.replace(marker,BASE.BASE.line('NIHOS_NATIVE_SDMMC_CODE',{**fields,key:value}))
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):
                NATIVE.check(changed,'sqlite',32<<20,image,'physical-device')
        for changed in [log.replace(marker,''),log+'\n'+marker]:
            with self.assertRaises(ValueError):NATIVE.check(changed,'sqlite',32<<20,image,'physical-device')
        del image['flash_boot']['functions']['sdmmc']
        with self.assertRaises(ValueError):NATIVE.check(log,'sqlite',32<<20,image,'physical-device')
