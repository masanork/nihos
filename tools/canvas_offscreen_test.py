import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('canvas_offscreen', Path(__file__).with_name('check-canvas-offscreen.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Records(unittest.TestCase):
    def test_valid_and_reject_invalid(self):
        record = 'NIHOS_NATIVE_CANVAS_OFFSCREEN checksum=549e3481 frame_bytes=001c2000 guard_bytes=00000010'
        valid = 'NIHOS_NATIVE_FP_PASS floating=0\n' + record + '\nNIHOS_NATIVE_CANVAS_OFFSCREEN_PASS\n'
        module.validate_records(valid)
        for bad in (valid.replace('549e3481', '549e3480'), valid.replace('001c2000', '00000000'),
                    valid.replace('00000010', '00000000'), valid + record + '\n',
                    valid.replace('NIHOS_NATIVE_FP_PASS', 'missing'),
                    valid + 'NIHOS_NATIVE_FAIL', valid.replace('_PASS\n', '_FAIL\n')):
            with self.subTest(bad=bad):
                with self.assertRaises(ValueError):
                    module.validate_records(bad)
