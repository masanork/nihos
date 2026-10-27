import importlib.util
from pathlib import Path
import unittest
SPEC=importlib.util.spec_from_file_location('auto_check',Path(__file__).with_name('check-native-auto-log.py'))
C=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(C)
def record(tag,names,values):return 'NIHOS_NATIVE_CARD_AUTO_'+tag+''.join(f' {n}={v:08x}' for n,v in zip(names,values))+'\n'
class AutoTests(unittest.TestCase):
    def test_public_notice_transitions_never_restart_or_darken_the_panel(self):
        a=record('DISPLAY',C.NOTICE,(0,1,0,32,1,0))
        b=record('DISPLAY',C.NOTICE,(1,1,0,64,1,0))
        c=record('DISPLAY',C.NOTICE,(3,1,0,120,1,0))
        self.assertEqual(len(C.check_notices(a+b+c)),3)
        for values in ((3,2,0,120,1,0),(3,1,1,120,1,0),(3,1,0,120,0,0),
                       (3,1,0,120,1,1),(1,1,0,120,1,0),(3,1,0,64,1,0)):
            with self.subTest(values=values),self.assertRaises(ValueError):
                C.check_notices(a+b+record('DISPLAY',C.NOTICE,values))
        with self.assertRaises(ValueError):C.check_notices(a+b)
    def test_detection_requires_clean_zero_credentials_and_a_removal_before_next_job(self):
        a=record('DETECTED',C.DETECTED,(1,1,0,0,2,1))
        remove=record('REMOVED',('job',),(1,))
        b=record('DETECTED',C.DETECTED,(2,2,0,0,2,1))
        self.assertEqual(C.check_auto(a+remove+b,False,(1,2))['qualified_kinds'],[1,2])
        for log in (a+b,(a+remove+b).replace('pin1_verifies=00000000','pin1_verifies=00000001'),a+remove+b+remove):
            with self.assertRaises(ValueError):C.check_auto(log,False,(1,2))
        self.assertEqual(C.NATIVE.fixed_record(record('REMOVED',('job',),(10,)),'NIHOS_NATIVE_CARD_AUTO_REMOVED',('job',))['job'],10)
    def test_full_licence_requires_both_budgets_all_fields_photo_and_final_erasure(self):
        log=record('DETECTED',C.DETECTED,(1,2,0,0,2,1))
        log+=record('SELECTED',('job','kind'),(1,2))
        log+=record('PROMPT',C.PROMPT,(1,2,1,3,3,0,0))
        log+=record('PROMPT',C.PROMPT,(1,2,2,3,3,1,0))
        log+=record('RESULT',C.RESULT,(1,2,0,0,0x9000,1,1,31,1,0,31,0,0,2,1,0))
        log+=record('DONE',C.DONE,(1,2,0,1,1,31,1,31,0,0,2,1,1,0))
        self.assertEqual(C.check_auto(log,True,(2,))['qualified_kinds'],[2])
        for old,new in [('pin2_verifies=00000001','pin2_verifies=00000002'),('erased=00000001','erased=00000000'),('photo_decoded=00000001','photo_decoded=00000000'),('missing=00000000','missing=00000001')]:
            with self.subTest(old=old),self.assertRaises(ValueError):C.check_auto(log.replace(old,new),True,(2,))
        with self.assertRaises(ValueError):C.check_auto(log,False,(2,))
        first=record('PROMPT',C.PROMPT,(1,2,1,3,3,0,0))
        second=record('PROMPT',C.PROMPT,(1,2,2,3,3,1,0))
        for altered in (log.replace(first,''),log.replace(second,''),log.replace(first,first+first),
                        log.replace(first+second,second+first),
                        log.replace('DETECTED job=00000001 kind=00000002','DETECTED job=00000001 kind=00000001'),
                        record('REMOVED',('job',),(1,))+log,
                        log+record('REMOVED',('job',),(2,))):
            with self.assertRaises(ValueError):C.check_auto(altered,True,(2,))
    def test_myna_namespace_menu_and_ten_attempt_gate(self):
        log=record('DETECTED',C.DETECTED,(1,4,0,0,2,1))
        log+=record('SELECTED',('job','kind'),(1,4))
        log+=record('PROMPT',C.PROMPT,(1,4,3,10,255,0,0))
        log+=record('RESULT',C.RESULT,(1,4,0,0,0x9000,1,0,7,1,0,7,0,0,2,1,0))
        log+=record('DONE',C.DONE,(1,4,0,1,0,7,1,7,0,0,2,1,1,0))
        result=C.check_auto(log,True,(4,))
        self.assertEqual(result['qualified_kinds'],[4]);self.assertEqual(result['signature_verified_jobs'],[])
        for old,new in [('pin_index=00000003','pin_index=00000000'),('pin1_remaining=0000000a','pin1_remaining=00000001'),('verification=00000001','verification=00000003')]:
            with self.subTest(old=old),self.assertRaises(ValueError):C.check_auto(log.replace(old,new),True,(4,))
        with self.assertRaises(ValueError):C.check_auto(log.replace(record('SELECTED',('job','kind'),(1,4)),''),True,(4,))
    def test_crypto_boot_evidence_is_bound_to_read_profile_and_stack_guard(self):
        image={'automatic_cards':{'read_enabled':True},'keypad_storage':{'ui_mode':'runtime'},'card_text':{'executable':True,'writable':False}}
        log='NIHOS_NATIVE_USB_MODE enabled=1\n'+record('BOOT',('selftest','error_code','stack_used','erased','crypto_selftest','crypto_stack'),(1,0,1024,1,1,12000))
        self.assertEqual(C.NATIVE.check_authenticated_owner(log,image,'physical-device')['crypto_selftest'],1)
        for old,new in [('crypto_selftest=00000001','crypto_selftest=00000000'),('crypto_stack=00002ee0','crypto_stack=0000ff80'),('erased=00000001','erased=00000000')]:
            with self.assertRaises(ValueError):C.NATIVE.check_authenticated_owner(log.replace(old,new),image,'physical-device')
        image['automatic_cards']['read_enabled']=False
        with self.assertRaises(ValueError):C.NATIVE.check_authenticated_owner(log,image,'physical-device')
if __name__=='__main__':unittest.main()
