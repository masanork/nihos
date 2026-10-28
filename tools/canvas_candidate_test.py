import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import prepare_canvas_candidate as candidate


class CanvasCandidateTest(unittest.TestCase):
    def test_rejects_wrong_options_and_mismatched_image(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'loader/bootloader').mkdir(parents=True)
            (root / 'loader/partition_table').mkdir(parents=True)
            (root / 'loader/bootloader/bootloader.bin').write_bytes(b'boot')
            (root / 'loader/partition_table/partition-table.bin').write_bytes(b'partition')
            image = b'NIHOS_NATIVE_CANVAS_PATTERN'
            elf = b'elf'
            (root / 'nihos-native.bin').write_bytes(image)
            (root / 'nihos-native.elf').write_bytes(elf)
            opts = ''.join(f'pub const {n} = {v};\n' for n, v in (
                ('canvas_demo', 'true'), ('qualification', 'true'), ('display_scanout', 'true'),
                ('psram_200', 'true'), ('console', 'false'), ('console_live', 'false'),
                ('card_read', 'false'), ('keypad_demo', 'false'), ('network', 'false'),
                ('devices', 'false'), ('usb', 'false'), ('sdmmc', 'false')))
            (root / 'native_options.zig').write_text(opts)
            (root / 'image-audit.json').write_text(json.dumps({
                'rtos_linked': False, 'memory': {'profile': 'device'},
                'image_sha256': hashlib.sha256(image).hexdigest(),
                'elf_sha256': hashlib.sha256(elf).hexdigest()}))
            self.assertFalse(candidate.inspect(root)['physical_tested'])
            (root / 'native_options.zig').write_text(opts.replace('canvas_demo = true', 'canvas_demo = false'))
            with self.assertRaises(ValueError):
                candidate.inspect(root)
            (root / 'native_options.zig').write_text(opts)
            (root / 'nihos-native.bin').write_bytes(image + b'x')
            with self.assertRaises(ValueError):
                candidate.inspect(root)


if __name__ == '__main__':
    unittest.main()
