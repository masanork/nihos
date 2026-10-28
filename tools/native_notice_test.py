"""Execute the actual SRAM notice builder and publication logic on the host."""
from pathlib import Path
import ctypes
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeNoticeTest(unittest.TestCase):
    def test_real_boot_raster_and_plan_fit_font_reserved_base(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)
            zig = str(ROOT / '.tools/zig-0.17.0/zig')
            library = path / ('boot.dylib' if sys.platform == 'darwin' else 'boot.so')
            subprocess.run([zig, 'build-lib', '-dynamic', '-OReleaseSafe', str(ROOT / 'src/card_boot_preview.zig'),
                            '-femit-bin=' + str(library)], check=True, capture_output=True)
            renderer = ctypes.CDLL(str(library))
            renderer.paint.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t]
            renderer.paint.restype = ctypes.c_bool
            renderer.spans.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.c_size_t,
                                       ctypes.POINTER(ctypes.c_uint32), ctypes.c_size_t]
            renderer.spans.restype = ctypes.c_size_t
            frame = (ctypes.c_uint8 * (720 * 1280 * 2))()
            plan = (ctypes.c_uint32 * (2048 * 4))()
            self.assertTrue(renderer.paint(frame, len(frame)))
            count = renderer.spans(frame, len(frame), plan, 2048)
            self.assertTrue(0 < count <= 1280)
            (path / 'frame.bin').write_bytes(bytes(frame))
            (path / 'plan.bin').write_bytes(bytes(plan)[:count * 16])
            binary = path / 'capacity'
            subprocess.run([zig, 'cc', '-std=c17', '-O2', '-UNDEBUG', '-Wall', '-Wextra', '-Werror',
                            '-Wno-unused-function', '-fsanitize=undefined',
                            str(ROOT / 'probes/display_notice/capacity-replay.c'), '-o', str(binary)],
                           check=True, capture_output=True)
            result = subprocess.run([str(binary), str(path / 'frame.bin'), str(path / 'plan.bin')],
                                    check=True, capture_output=True, text=True)
            self.assertIn('Real boot pixels fit font-reserved base SRAM', result.stdout)

    def test_candidate_capacity_is_checked_before_live_scene_retirement(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'capacity-replay'
            subprocess.run([str(ROOT / '.tools/zig-0.17.0/zig'), 'cc', '-std=c17', '-O2', '-UNDEBUG',
                            '-Wall', '-Wextra', '-Werror', '-Wno-unused-function', '-fsanitize=undefined',
                            str(ROOT / 'probes/display_notice/capacity-replay.c'), '-o', str(binary)],
                           check=True, capture_output=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn('Display capacity replay passed', result.stdout)

    def test_base_free_sram_reservations_competing_owners_and_reuse(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'sram-replay'
            subprocess.run([str(ROOT / '.tools/zig-0.17.0/zig'), 'cc', '-std=c17', '-O2', '-UNDEBUG',
                            '-Wall', '-Wextra', '-Werror', '-fsanitize=undefined',
                            str(ROOT / 'probes/display_notice/sram-replay.c'), '-o', str(binary)],
                           check=True, capture_output=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn('Base SRAM replay passed', result.stdout)

    def test_actual_dma_pixels_are_checked_independently_of_backlight_counters(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'pixels-replay'
            subprocess.run([str(ROOT / '.tools/zig-0.17.0/zig'), 'cc', '-std=c17', '-O2', '-UNDEBUG',
                            '-Wall', '-Wextra', '-Werror', str(ROOT / 'probes/display_notice/pixels-replay.c'),
                            '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn('Scene pixel replay passed', result.stdout)

    def test_scene_retirement_keeps_panel_lit_and_failed_dma_borrowed(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / 'retire-replay'
            subprocess.run([str(ROOT / '.tools/zig-0.17.0/zig'), 'cc', '-std=c17', '-O2', '-UNDEBUG',
                            '-Wall', '-Wextra', '-Werror', str(ROOT / 'probes/display_notice/retire-replay.c'),
                            '-o', str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn('Scene retirement replay passed', result.stdout)

    def test_frame_handoff_and_failed_candidates_preserve_active_bank(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary) / "notice-replay"
            subprocess.run([str(ROOT / ".tools/zig-0.17.0/zig"), "cc", "-std=c17", "-O2", "-UNDEBUG",
                            "-Wall", "-Wextra", "-Werror", str(ROOT / "probes/display_notice/replay.c"),
                            "-o", str(binary)], check=True, capture_output=True)
            result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
            self.assertIn("Public notice bank replay passed", result.stdout)
