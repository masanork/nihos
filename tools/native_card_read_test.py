"""Authenticated receipts use metadata only and never accept repeat VERIFY."""
import importlib.util
from pathlib import Path
import unittest
SPEC=importlib.util.spec_from_file_location('read_check',Path(__file__).with_name('check-native-card-read-log.py'))
CHECK=importlib.util.module_from_spec(SPEC);SPEC.loader.exec_module(CHECK)
def record(tag,names,values):return tag+''.join(f' {n}={v:08x}' for n,v in zip(names,values))+'\n'
def complete():
    fields=(1,0,3,255,1,2,1,15,1)
    return record('NIHOS_NATIVE_CARD_READ_READY',('remaining_before','verifies','preflight_cut'),(3,0,1))+record('NIHOS_NATIVE_CARD_READ_RESULT',CHECK.FIELDS,fields)+record('NIHOS_NATIVE_CARD_READ_DONE',CHECK.DONE,fields+(15,0,1))
class ReadTests(unittest.TestCase):
    def test_authenticated_preparation_does_not_masquerade_as_boot_usb_probe(self):
        image = {'keypad_storage': {'ui_mode':'runtime', 'font_bytes':408096},
                 'card_text': {'writable':False,'executable':True}}
        log = 'NIHOS_NATIVE_USB_MODE enabled=1\n' + complete()
        self.assertEqual(CHECK.NATIVE.check_authenticated_owner(log,image,'physical-device')['verifies'],0)
        for changed, audit, evidence in ((log, {}, 'physical-device'), (log,image,'host'),
                (log.replace('preflight_cut=00000001','preflight_cut=00000000'),image,'physical-device'),
                (log+'NIHOS_NATIVE_USB status=00000001\n',image,'physical-device')):
            with self.assertRaises(ValueError):CHECK.NATIVE.check_authenticated_owner(changed,audit,evidence)

    def test_one_shot_read_metadata_passes(self):
        self.assertEqual(CHECK.check_read(complete())['done']['erased'],1)
    def test_missing_preflight_repeat_verify_last_attempt_incomplete_display_and_uncleared_result_fail(self):
        for old,new in [('preflight_cut=00000001','preflight_cut=00000000'),('verifies=00000001','verifies=00000002'),('remaining_before=00000003','remaining_before=00000001'),('shown=0000000f','shown=00000007'),('erased=00000001','erased=00000000'),('remaining_after=000000ff','remaining_after=00000003'),('vbus_off=00000001','vbus_off=00000000')]:
            with self.subTest(old=old),self.assertRaises(ValueError):CHECK.check_read(complete().replace(old,new))
        with self.assertRaises(ValueError):CHECK.check_read(complete()+complete())
        with self.assertRaises(ValueError):CHECK.check_read(complete()+'NIHOS_NATIVE_KEYPAD_EVENT effect=00000001 count=00000001\n')
if __name__=='__main__':unittest.main()
