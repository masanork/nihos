import struct
import unittest
import native_image_test as IMAGE
import high_sram_checks_test as HIGH

NATIVE = HIGH.NATIVE


def fixture():
    log,image,_,_ = HIGH.fixture()
    image['broker'] = {'version':2,'metadata_bytes':12912,'internal_bytes':208*1024,'external_bytes':30<<20,
                       'internal_floor':64*1024,'external_floor':17*(1<<19)}
    values = [1,4,12912,208*1024,208*1024,30<<20,30<<20,64*1024,17*(1<<19),
              4<<20,4<<20,8<<20,8<<20,0x50001,0x60001,16,15,8,4,4,4,4,3,2,16384,1,1600,
              0x70001,0x80001,1,1,1,512,0,0,1,1,1,1,1]
    sd=NATIVE.fixed_record(log,'NIHOS_NATIVE_SDMMC',NATIVE.SDMMC_FIELDS)
    values[33]=values[34]=sd['crc0']
    record = HIGH.line('NIHOS_NATIVE_BROKER',NATIVE.BROKER_FIELDS,values)
    log += '\n'+record
    return log,image,record,dict(zip(NATIVE.BROKER_FIELDS,values))


class BrokerLogChecks(unittest.TestCase):
    def test_both_domains_recover_after_real_exit_reap_and_rebind(self):
        log,image,_,_=fixture()
        result=NATIVE.check(log,'sqlite',32<<20,image,'physical-device')
        self.assertEqual(result['broker']['reaped'],4)
        self.assertEqual(result['broker']['internal_free'],208*1024)

    def test_every_missing_measurement_or_failed_gate_is_rejected(self):
        log,image,record,fields=fixture()
        for key in NATIVE.BROKER_FIELDS:
            if key in ('io_crc','expected_crc') and fields[key] == 0: continue
            changed={**fields,key:0}
            with self.subTest(key=key),self.assertRaises(ValueError):
                NATIVE.check_broker(log.replace(record,HIGH.BASE.BASE.line('NIHOS_NATIVE_BROKER',changed)),image,'physical-device')
        for changed in [log.replace(record,''),log+'\n'+record]:
            with self.assertRaises(ValueError):NATIVE.check_broker(changed,image,'physical-device')

    def test_floors_and_pin_recovery_cannot_be_replaced_with_free_byte_totals(self):
        log,image,record,fields=fixture()
        for key,value in [('internal_floor',0),('external_floor',0),('pin_waited',1),('borrow_completed',1),('reaped',1),('stale_identity',1)]:
            with self.subTest(key=key),self.assertRaises(ValueError):
                NATIVE.check_broker(log.replace(record,HIGH.BASE.BASE.line('NIHOS_NATIVE_BROKER',{**fields,key:value})),image,'physical-device')

    def test_owner_identity_must_reuse_slot_with_next_generation(self):
        log,image,record,fields=fixture()
        for value in [fields['client'],0x70001,0x60002]:
            with self.assertRaises(ValueError):
                NATIVE.check_broker(log.replace(record,HIGH.BASE.BASE.line('NIHOS_NATIVE_BROKER',{**fields,'replacement':value})),image,'physical-device')

    def test_orphan_or_emulator_evidence_cannot_qualify_handoff(self):
        log,image,_,_=fixture()
        for audit,evidence in [(None,'physical-device'),({},'physical-device'),(image,'emulator')]:
            with self.assertRaises(ValueError):NATIVE.check_broker(log,audit,evidence)
        with self.assertRaises(ValueError):NATIVE.check(log,'sqlite',64<<20,image,'physical-device')

    def test_completed_io_requires_kill_pin_crc_and_discarded_reply(self):
        log,image,record,fields=fixture()
        for key,value in [('io_crc',fields['io_crc'] ^ 1),('expected_crc',fields['expected_crc'] ^ 1),
                          ('io_bytes',4096),('responses',16),('after_forced',0x80002),
                          ('forced_client',fields['replacement']),('pinned_after_kill',0),
                          ('completion_after_exit',0),('discarded_responses',0)]:
            with self.subTest(key=key),self.assertRaises(ValueError):
                NATIVE.check(log.replace(record,HIGH.BASE.BASE.line('NIHOS_NATIVE_BROKER',{**fields,key:value})),
                             'sqlite',32<<20,image,'physical-device')

    def test_version_one_normal_exit_receipts_remain_replayable(self):
        log,image,record,fields=fixture()
        image['broker']['version']=1
        old={key:fields[key] for key in NATIVE.BROKER_FIELDS_V1}
        old.update(requests=9,responses=9,rejected=5,exits=2,reaped=2,pin_waited=2,
                   borrow_completed=2,stale_identity=2,stale_lease=1)
        legacy=HIGH.BASE.BASE.line('NIHOS_NATIVE_BROKER',old)
        result=NATIVE.check(log.replace(record,legacy),'sqlite',32<<20,image,'physical-device')
        self.assertEqual(result['broker']['reaped'],2)
        image['broker']['version']=2
        with self.assertRaises(ValueError):NATIVE.check(log.replace(record,legacy),'sqlite',32<<20,image,'physical-device')


class BrokerImageChecks(unittest.TestCase):
    def fixture(self):
        module=IMAGE.MODULE
        data=struct.pack('<14I',*module.BROKER_CONFIG,12912)
        symbols={name:0x4ff10000+index*32 for index,name in enumerate(module.BROKER_HOOKS)}
        return module,data,symbols

    def test_fixed_ranges_keep_metadata_payload_and_ipc_disjoint(self):
        module,data,symbols=self.fixture()
        r=module.audit_broker(data,symbols,0x4ff00000,0x4ff28000,0x4ff1be00,'device')
        self.assertEqual(r['internal_bytes'],208*1024)
        self.assertEqual(r['metadata_bytes'],12912)

    def test_each_shifted_range_or_insufficient_metadata_reserve_is_rejected(self):
        module,data,symbols=self.fixture()
        for index in range(14):
            values=list(struct.unpack('<14I',data));values[index]=0
            with self.subTest(index=index),self.assertRaises(ValueError):
                module.audit_broker(struct.pack('<14I',*values),symbols,0x4ff00000,0x4ff28000,0x4ff1be00,'device')
        values=list(struct.unpack('<14I',data));values[-1]=16385
        with self.assertRaises(ValueError):module.audit_broker(struct.pack('<14I',*values),symbols,0x4ff00000,0x4ff28000,0x4ff1be00,'device')

    def test_irq_hooks_cannot_move_to_flash_or_external_memory(self):
        module,data,symbols=self.fixture()
        for hook in module.BROKER_HOOKS:
            for address in [0x40020000,0x48200000,0]:
                with self.subTest(hook=hook),self.assertRaises(ValueError):
                    module.audit_broker(data,{**symbols,hook:address},0x4ff00000,0x4ff28000,0x4ff1be00,'device')
        with self.assertRaises(ValueError):module.audit_broker(data,symbols,0x4ff00000,0x4ff28000,0x4ff1c040,'device')
        with self.assertRaises(ValueError):module.audit_broker(data,symbols,0x4ff00000,0x4ff28000,0x4ff1be00,'emulator')

    def test_old_images_need_only_their_original_resident_hooks(self):
        module,data,symbols=self.fixture()
        values=list(struct.unpack('<14I',data));values[0]=1
        old={key:value for key,value in symbols.items() if key in module.BROKER_HOOKS_V1}
        result=module.audit_broker(struct.pack('<14I',*values),old,0x4ff00000,0x4ff28000,0x4ff1be00,'device')
        self.assertEqual(result['version'],1)
        with self.assertRaises(ValueError):module.audit_broker(data,old,0x4ff00000,0x4ff28000,0x4ff1be00,'device')
