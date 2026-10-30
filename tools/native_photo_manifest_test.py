"""Regenerated fonts must preserve each card profile's foreground contract."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('photo_manifest', Path(__file__).with_name('native-photo-manifest.py'))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PhotoManifestTests(unittest.TestCase):
    def test_manual_canvas_is_only_admitted_in_manual_profiles(self):
        for automatic, scene in ((False, False), (True, False), (True, True)):
            with self.subTest(automatic=automatic, scene=scene), tempfile.TemporaryDirectory() as directory:
                build = Path(directory)
                (build / 'native_options.zig').write_text(
                    'pub const card_auto = %s;\npub const card_auto_probe = true;\n'
                    'pub const card_scene_exercise = %s;\n' %
                    (str(automatic).lower(), str(scene).lower()))
                (build / 'photo_stub.o').write_bytes(b'object fixture')
                with patch.object(sys, 'argv', ['native-photo-manifest.py', directory]), \
                        patch.object(MODULE.C, 'functions', return_value=['codec_stub']):
                    MODULE.main()
                manifest = json.loads((build / 'photo-manifest.json').read_text())
                manual = ['card_read.prepare', 'card_read.run', 'card_read.redraw',
                          'graphics.card_read_result.Canvas.sizedFlash']
                transport = ['usb_probe.Device.send', 'usb_probe.Device.scrub', 'usb_probe.Device.powerCut']
                expected = ([] if automatic else manual) + ['keypad_display.prepare', 'keypad_display.bind',
                            'keypad_display.paintTextures'] + ([] if scene else transport) + [
                            'display_runtime.start', 'display_runtime.replaceCard', 'main.resourceReport',
                            'main.stackReport', 'photo_runtime.prepare', 'photo_runtime.close']
                self.assertEqual(manifest['allowed_functions'], expected)


if __name__ == '__main__':
    unittest.main()
