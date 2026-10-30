import unittest
import storage_api_checks_test as BASE
NATIVE = BASE.NATIVE


def line(marker, fields, values):
    return marker + ''.join(f' {key}={value:08x}' for key,value in zip(fields,values))


def fixture():
    log,image = BASE.fixture()
    image['high_sram'] = {'tested_bytes':328*1024,'heap_bytes':208*1024,'guard_bytes':16*1024,
        'temporary_psram':{'start':'0x48030000','bytes':8<<20}}
    high = [1,328*1024,2,167936,167936,83968,83968,83968,208*1024,208*1024,16*1024,3,4,5,6,7,1]
    page = [1,0x48030000,8<<20,4<<20,4<<20,8<<20,8<<20,3145728,3145728,1,1]
    records = '\n'.join((line('NIHOS_NATIVE_HIGH_SRAM',NATIVE.HIGH_FIELDS,high),line('NIHOS_NATIVE_PAGE_LEASE',NATIVE.PAGE_FIELDS,page)))
    return log+'\n'+records,image,high,page


class HighSramChecks(unittest.TestCase):
    def test_bound_physical_log_checks_high_memory_and_exact_size_leases(self):
        log,image,_,_ = fixture()
        report = NATIVE.check(log,'sqlite',32<<20,image,'physical-device')
        self.assertEqual(report['high_sram']['free_bytes'],208*1024)
        self.assertEqual(report['page_lease']['charged8'],8<<20)

    def test_every_missing_failed_or_duplicate_measurement_is_rejected(self):
        log,image,high,page = fixture()
        for marker,fields,values in (('NIHOS_NATIVE_HIGH_SRAM',NATIVE.HIGH_FIELDS,high),('NIHOS_NATIVE_PAGE_LEASE',NATIVE.PAGE_FIELDS,page)):
            original = line(marker,fields,values)
            for index,key in enumerate(fields):
                changed = values.copy()
                changed[index] = 0
                with self.subTest(marker=marker,key=key),self.assertRaises(ValueError):
                    NATIVE.check_high(log.replace(original,line(marker,fields,changed)),image,'physical-device')
            for changed in (log.replace(original,''),log+'\n'+original):
                with self.assertRaises(ValueError): NATIVE.check_high(changed,image,'physical-device')

    def test_image_binding_and_device_profile_cannot_be_omitted(self):
        log,image,_,_ = fixture()
        for audit,evidence in ((None,'physical-device'),({},'physical-device'),(image,'emulator'),
                               ({**image,'memory':{'profile':'emulator'}},'physical-device')):
            with self.assertRaises(ValueError): NATIVE.check_high(log,audit,evidence)

    def test_doubled_backing_charge_fails_even_with_correct_payload_size(self):
        log,image,_,page = fixture()
        for index in (4,6):
            changed = page.copy()
            changed[index] *= 2
            with self.assertRaises(ValueError):
                NATIVE.check_high(log.replace(line('NIHOS_NATIVE_PAGE_LEASE',NATIVE.PAGE_FIELDS,page),line('NIHOS_NATIVE_PAGE_LEASE',NATIVE.PAGE_FIELDS,changed)),image,'physical-device')
