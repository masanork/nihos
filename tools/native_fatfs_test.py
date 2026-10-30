"""Negative controls for native fixture boundaries; these are synthetic records."""
import copy
import struct
import unittest
import zlib
import fatfs_native_profile as PROFILE
import native_image_test as IMAGE
import native_checks_test as BASE

LOG = BASE.MODULE

def line(marker, values):
    return marker + ''.join(' ' + key + '=' + format(value, '08x') for key, value in values.items())


def config():
    return {'version': 3, 'source': PROFILE.SOURCE, 'flash_end': '0x400d0000', 'c_no_inline': True,
            'sources': dict.fromkeys(PROFILE.SOURCES, 'a' * 64),
            'fixture': {'schema': 1, 'source': PROFILE.SOURCE, 'image_sha256': PROFILE.IMAGE_SHA256,
                'image_bytes': 1048576, 'fixture_id': int(PROFILE.IMAGE_SHA256[:8], 16),
                'upstream': PROFILE.UPSTREAM.copy(), 'payload_bytes': 3942, 'index_entries': 31}}


class NativeFatFsImageChecks(unittest.TestCase):
    def test_card_relay_needs_a_versioned_profile_and_rpc(self):
        c=config();c['card']={'version':4,'mode':'inserted','rpc':True,'cancel_relay':True,
            'source':PROFILE.CARD_SOURCE_RPC,'charged':65536,'sources':dict.fromkeys(PROFILE.CARD_SOURCES,'b'*64)}
        PROFILE.validate_profile(c)
        for key,value in (('version',3),('rpc',False),('cancel_relay',False),('cancel_relay',1)):
            bad=copy.deepcopy(c);bad['card'][key]=value
            with self.subTest(key=key,value=value),self.assertRaises(ValueError):PROFILE.validate_profile(bad)
        bad=copy.deepcopy(c);del bad['card']['cancel_relay']
        with self.assertRaises(ValueError):PROFILE.validate_profile(bad)
    def test_card_rpc_requires_its_own_input_wire_and_worker_stack_contract(self):
        c=config();c['card']={'version':3,'mode':'inserted','rpc':True,'source':PROFILE.CARD_SOURCE_RPC,
            'charged':65536,'rpc_parent_used':44928,'sources':dict.fromkeys(PROFILE.CARD_SOURCES,'b'*64)}
        image={'sqlite':{'fatfs_native':c},'memory':{'profile':'device'}}
        fields=dict.fromkeys(LOG.FATFS_FIELDS,1)
        fields.update(version=2,source=2,fixture_id=0,parent_used=44928,parent_charged=65536,
                      requests=11,replies=9,bytes=140,crc=42,owner_stack=3200,client_stack=352)
        card=dict.fromkeys(LOG.FATFS_CARD_FIELDS,1)
        card.update(sectors=4096,first=100,count=2048,partition=1,bytes=140,crc=42,repeated_crc=42,charged=65536)
        report=line('NIHOS_NATIVE_FATFS_RPC',fields)
        log='NIHOS_NATIVE_BROKER x\nNIHOS_NATIVE_IO_LIFETIMES x\nNIHOS_FATFS_SD_READY\n'+report+'\n'+line('NIHOS_NATIVE_FATFS_CARD',card)+'\n'+line('NIHOS_NATIVE_FATFS_CARD_STACK',dict(used=3200,preserved=1))+'\nNIHOS_NATIVE_FP_PASS floating=0\n'
        self.assertTrue(LOG.check_fatfs_native(log,image,'physical-device')['physical_sd_fatfs_qualified'])
        c['card'].update(version=4,cancel_relay=True)
        self.assertFalse(LOG.check_fatfs_native(log,image,'physical-device')['controller_abort_qualified'])
        for key,value in (('source',1),('requests',8),('parent_used',38656),('owner_stack',3920),('bytes',24)):
            bad=log.replace(report,line('NIHOS_NATIVE_FATFS_RPC',{**fields,key:value}))
            with self.subTest(key=key),self.assertRaises(ValueError):LOG.check_fatfs_native(bad,image,'physical-device')
        with self.assertRaises(ValueError):LOG.check_fatfs_native(log.replace('used=00000c80','used=00000c7c'),image,'physical-device')
    def test_inserted_card_mode_requires_its_own_source_and_version(self):
        c=config();c['card']={'version':2,'mode':'inserted','source':PROFILE.CARD_SOURCE_INSERTED,
            'charged':32768,'sources':dict.fromkeys(PROFILE.CARD_SOURCES,'b'*64)}
        PROFILE.validate_profile(c)
        for key,value in (('version',1),('mode','swap'),('source',PROFILE.CARD_SOURCE)):
            bad=copy.deepcopy(c);bad['card'][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError): PROFILE.validate_profile(bad)
        bad=copy.deepcopy(c);del bad['card']['mode']
        with self.assertRaises(ValueError):PROFILE.validate_profile(bad)
    def test_card_source_identity_is_required_in_addition_to_fixture(self):
        c = config()
        c['card'] = {'version':1,'source':PROFILE.CARD_SOURCE,'charged':32768,
                     'sources':dict.fromkeys(PROFILE.CARD_SOURCES,'b'*64)}
        PROFILE.validate_profile(c)
        for key in c['card']:
            bad=copy.deepcopy(c);bad['card'][key]=0
            with self.subTest(key=key),self.assertRaises((ValueError,TypeError)):
                PROFILE.validate_profile(bad)
    def test_card_records_require_read_consistency_teardown_and_source(self):
        c=config();c['card']={'version':1,'source':PROFILE.CARD_SOURCE,'charged':32768,
                             'sources':dict.fromkeys(PROFILE.CARD_SOURCES,'b'*64)}
        image={'sqlite':{'fatfs_native':c},'memory':{'profile':'device'}}
        values=dict.fromkeys(LOG.FATFS_CARD_FIELDS,1)
        values.update(sectors=4096,first=0,count=2048,partition=0,bytes=24,crc=42,repeated_crc=42,charged=32768)
        record=line('NIHOS_NATIVE_FATFS_CARD',values)
        log='NIHOS_NATIVE_FATFS_RPC x\nNIHOS_FATFS_SD_READY\n'+record+'\nNIHOS_NATIVE_FATFS_CARD_STACK used=00001000 preserved=00000001\nNIHOS_NATIVE_FP_PASS floating=0\n'
        self.assertFalse(LOG.check_fatfs_card(log,image,'physical-device')['native_rpc_over_sd_qualified'])
        for key in ('status','generation','count','bytes','reads','destroyed','charged','cleared','recovered','repeated_crc'):
            bad=log.replace(record,line('NIHOS_NATIVE_FATFS_CARD',{**values,key:0}))
            with self.subTest(key=key),self.assertRaises(ValueError):LOG.check_fatfs_card(bad,image,'physical-device')
        for audit,evidence in ((None,'physical-device'),(image,'emulator')):
            with self.assertRaises(ValueError):LOG.check_fatfs_card(log,audit,evidence)
        with self.assertRaises(ValueError):LOG.check_fatfs_card(log+record+'\n',image,'physical-device')
    def test_log_flash_window_requires_complete_physical_fixture_profile(self):
        spans = dict(text_start=0x40020000, text_end=0x400ae300,
                     rodata_start=0x400ae300, rodata_end=0x400c4e80)
        image = {'memory': {'profile': 'device'}, 'sqlite': {'fatfs_native': config()}}
        LOG.check_sqlite_spans(spans, image, 'physical-device')
        for audit, evidence in ((None, 'physical-device'), ({}, 'physical-device'),
                                (image, 'emulator')):
            with self.subTest(audit=audit, evidence=evidence), self.assertRaises(ValueError):
                LOG.check_sqlite_spans(spans, audit, evidence)
        for key in config():
            bad = copy.deepcopy(image)
            bad['sqlite']['fatfs_native'][key] = 0
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOG.check_sqlite_spans(spans, bad, 'physical-device')
        with self.assertRaises(ValueError):
            LOG.check_sqlite_spans({**spans, 'rodata_end': 0x400d0001}, image, 'physical-device')
        LOG.check_sqlite_spans({**spans, 'rodata_end': 0x400c0000}, None, 'emulator')

    def test_profile_pins_image_upstream_sources_and_flash_window(self):
        original = config()
        PROFILE.validate_profile(original)
        for key in original:
            bad = copy.deepcopy(original)
            bad[key] = {} if key in ('sources', 'fixture') else 0
            with self.subTest(key=key), self.assertRaises(ValueError):
                PROFILE.validate_profile(bad)
        for key in original['fixture']:
            bad = copy.deepcopy(original)
            bad['fixture'][key] = 0
            with self.subTest(fixture=key), self.assertRaises(ValueError):
                PROFILE.validate_profile(bad)

    def test_version_one_source_manifest_remains_replayable(self):
        old = config(); old['version'] = 1
        old['sources'] = dict.fromkeys(PROFILE.SOURCES_V1, 'a' * 64)
        PROFILE.validate_profile(old)
        old['version'] = 2
        with self.assertRaises(ValueError): PROFILE.validate_profile(old)

    def test_version_two_sources_replay_and_new_trap_reserve_is_required(self):
        old = config(); old['version'] = 2
        old['sources'] = dict.fromkeys(PROFILE.SOURCES_V2, 'a' * 64)
        PROFILE.validate_profile(old)
        old['version'] = 3
        with self.assertRaises(ValueError): PROFILE.validate_profile(old)
        with self.assertRaisesRegex(ValueError, 'trap reserve'):
            PROFILE.audit(config(), {}, {}, 0, 1, 0, b'', [], {})

    def test_expanded_flash_requires_explicit_fixture_window(self):
        module = IMAGE.MODULE
        args = ('.flash.sqlrodata', 1, 2, 0x400bfff0, 32, True)
        with self.assertRaises(ValueError): module.audit_flash_section(*args)
        module.audit_flash_section(*args, sql_end=module.FATFS_SQL_END)
        with self.assertRaises(ValueError):
            module.audit_flash_section('.flash.sqlrodata', 1, 2, 0x400cfff0, 32, True, module.FATFS_SQL_END)

    def test_sparse_zero_sectors_and_exact_rle_decode(self):
        payload = bytes([255, 4, 255, 4, 2, 4])
        index = struct.pack('<IHH', 1, 0, len(payload))
        self.assertEqual(PROFILE.decode_fixture(payload, index, 2), bytes(512) + bytes([4]) * 512)

    def test_bad_runs_indices_geometry_and_unindexed_bytes_are_rejected(self):
        good = bytes([255, 0, 255, 0, 2, 0])
        index = struct.pack('<IHH', 0, 0, len(good))
        cases = [(good, index, 0), (good, index, 2049), (good, index[:-1], 2),
                 (good, struct.pack('<IHH', 2, 0, 6), 2), (good, struct.pack('<IHH', 0, 1, 6), 2),
                 (good, struct.pack('<IHH', 0, 0, 5), 2), (good, index + index, 2),
                 (good + bytes([1, 0]), index, 2), (bytes([0, 0, 255, 0, 2, 0]), index, 2),
                 (bytes([255, 0, 255, 0, 3, 0]), index, 2), (bytes([255, 0, 255, 0, 1, 0]), index, 2)]
        for args in cases:
            with self.subTest(args=args), self.assertRaises(ValueError): PROFILE.decode_fixture(*args)

    def test_every_irq_hook_and_notification_must_remain_resident(self):
        symbols = {name: 0x4ff01000 + i * 32 for i, name in enumerate(PROFILE.HOOKS)}
        sizes = {}
        for i, (name, size) in enumerate(PROFILE.WORDS.items()):
            key = 'fatfs_runtime.' + name
            symbols[key] = 0x4ff02000 + i * 32
            sizes[key] = size
        for key in symbols:
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, 'SRAM'):
                PROFILE.audit({**config(), 'version': 2, 'sources': dict.fromkeys(PROFILE.SOURCES_V2, 'a' * 64)}, {**symbols, key: 0x40020000}, sizes, 0x4ff00000, 0x4ff28000,
                              0x400c0000, b'', [], {})

    def test_guard_lfn_frame_cannot_be_inlined_back_into_wrapper(self):
        PROFILE.audit_guard_frames([{'functions': ['nih_fatfs_guard_open'], 'bytes': 80}])
        for rows in ([], [{'functions': ['nih_fatfs_guard_open'], 'bytes': 1248}]):
            with self.assertRaises(ValueError): PROFILE.audit_guard_frames(rows)

    def test_actual_frame_sizes_reject_missing_metadata_and_old_large_frames(self):
        objects = {'sql_broker_runtime.o': {'functions': ['owner', 'client']}}
        symbols = dict(owner=0x40020000, client=0x40020100)
        rows = [{'functions': ['owner'], 'bytes': 496}, {'functions': ['client'], 'bytes': 128}]
        self.assertEqual(PROFILE.audit_zig_frames(rows, objects, symbols)['maximum_bytes'], 496)
        for large in (1025, 4320, 5872, 7008):
            with self.subTest(frame=large), self.assertRaisesRegex(ValueError, 'ceiling'):
                PROFILE.audit_zig_frames([rows[0], {**rows[1], 'bytes': large}], objects, symbols)
        with self.assertRaisesRegex(ValueError, 'missing'):
            PROFILE.audit_zig_frames(rows[:1], objects, symbols)


class NativeFatFsLogChecks(unittest.TestCase):
    def fixture(self):
        image = {'sqlite': {'fatfs_native': config()}, 'memory': {'profile': 'device'}}
        values = dict.fromkeys(LOG.FATFS_FIELDS, 1)
        values.update(fixture_id=image['sqlite']['fatfs_native']['fixture']['fixture_id'], parent_used=38656,
            parent_charged=65536, requests=8, replies=6, bytes=24,
            crc=zlib.crc32(b'nihos read-only fixture\n'), owner_stack=3500, client_stack=1000)
        record = line('NIHOS_NATIVE_FATFS_RPC', values)
        log = 'NIHOS_NATIVE_BROKER \nNIHOS_NATIVE_IO_LIFETIMES \n' + record + '\nNIHOS_NATIVE_FP_PASS floating=0\n'
        return log, image, record, values

    def test_success_still_labels_source_as_embedded_not_physical_sd(self):
        log, image, _, _ = self.fixture()
        result = LOG.check_fatfs_native(log, image, 'physical-device')
        self.assertFalse(result['physical_sd_fatfs_qualified'])
        self.assertEqual(result['bytes'], 24)

    def test_every_failed_gate_bad_stack_missing_or_duplicate_marker_is_rejected(self):
        log, image, record, values = self.fixture()
        for key in values:
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOG.check_fatfs_native(log.replace(record, line('NIHOS_NATIVE_FATFS_RPC', {**values, key: 0})), image, 'physical-device')
        for bad in (log.replace(record, ''), log + record + '\n', log.replace('source=00000001', 'source=00000002'),
                    log.replace('NIHOS_NATIVE_IO_LIFETIMES ', 'missing '),
                    log.replace('owner_stack=00000dac', 'owner_stack=00000f50')):
            with self.assertRaises(ValueError): LOG.check_fatfs_native(bad, image, 'physical-device')

    def test_orphan_emulator_unknown_source_or_reordered_phases_cannot_qualify(self):
        log, image, record, _ = self.fixture()
        for audit, evidence in ((None, 'physical-device'), ({}, 'physical-device'), (image, 'emulator')):
            with self.assertRaises(ValueError): LOG.check_fatfs_native(log, audit, evidence)
        for source in ('SD FatFs', '', None):
            bad = copy.deepcopy(image); bad['sqlite']['fatfs_native']['source'] = source
            with self.assertRaises(ValueError): LOG.check_fatfs_native(log, bad, 'physical-device')
        with self.assertRaises(ValueError):
            LOG.check_fatfs_native(record + '\n' + log.replace(record, ''), image, 'physical-device')
        self.assertIsNone(LOG.check_fatfs_native('', None, 'emulator'))


if __name__ == '__main__':
    unittest.main()
