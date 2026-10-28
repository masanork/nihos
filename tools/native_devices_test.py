"""Reject incompatible all-device profiles before linking or touching hardware."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DeviceProfileTests(unittest.TestCase):
    def test_invalid_profiles_fail_before_artifact_creation(self):
        base = {key: value for key, value in os.environ.items() if not key.startswith('NIHOS_NATIVE_')}
        base.update(NIHOS_NATIVE_DEVICES='1', NIHOS_NATIVE_DISPLAY='2', NIHOS_NATIVE_PSRAM_200='1',
                    NIHOS_NATIVE_CONSOLE='1', NIHOS_NATIVE_CONSOLE_LIVE='1')
        cases = ({'NIHOS_NATIVE_DEVICES': '2'}, {'NIHOS_NATIVE_AUDIO': '1'},
                 {'NIHOS_NATIVE_MICROPHONE': '1'}, {'NIHOS_NATIVE_RS485': '1'},
                 {'NIHOS_NATIVE_BOOT_TEST': '1'}, {'NIHOS_NATIVE_DISPLAY': '3'},
                 {'NIHOS_NATIVE_PSRAM_200': '0'}, {'NIHOS_NATIVE_NORMAL_STORAGE': '2'},
                 {'NIHOS_NATIVE_NORMAL_STORAGE': '1', 'NIHOS_NATIVE_USB': '1'},
                 {'NIHOS_NATIVE_NORMAL_STORAGE': '1', 'NIHOS_NATIVE_SDMMC': '1'})
        for changes in cases:
            with self.subTest(changes=changes), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / 'must-not-exist'
                result = subprocess.run(['sh', str(ROOT / 'tools/build-native-elf.sh'), 'device', str(output), 'integer'],
                                        env={**base, **changes}, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists(), result.stdout + result.stderr)


if __name__ == '__main__':
    unittest.main()
