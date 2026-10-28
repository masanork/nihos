"""Admission, immutable font input and ownership-evidence regressions."""
import copy
import hashlib
import importlib.util
from pathlib import Path
import unittest


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


AUDIT = load("graphics_image", "check-native-image.py")
LOG = load("graphics_log", "check-native-graphics.py")


class NativeGraphicsTests(unittest.TestCase):
    def record(self):
        return dict(zip(LOG.FIELDS, [1, 0x10003, 16, 0x40023004, 16 << 20, 16 << 20,
                                    1310976, 65792, 0x4ff6e010, 0x4ff76000, 16928, 12, 8, 14,
                                    694, 17224, 21, 20, 11, 10, 1, 9, 65792, 0, 10]))

    def exchange(self):
        return dict(zip(LOG.EXCHANGE_FIELDS, [10, 10, 10, 10, 20, 0, 1, 1, 5, 3, 2, 5, 3072]))

    def texts(self):
        glyph = dict(zip(LOG.GLYPH_FIELDS[2:], [42, 0, 0, 24, 1536, 0, 0, 0, 0, 20, 20, 20, 0]))
        return [{**dict(zip(LOG.TEXT_FIELDS, row)), "glyphs": [glyph.copy()] if row[1] else []}
                for row in [(5, 1, 11, 0, 1, 400, 888), (6, 0, 0, 1, 0, 0, 0), (7, 0, 0, 2, 0, 0, 0), (8, 1, 22, 0, 1, 400, 999), (9, 1, 33, 0, 1, 400, 1000)]]

    def test_complete_record_and_hashes_require_cleanup_and_real_render_interrupts(self):
        graphics = {"functions": {"graphics_font_link_probe": {"start": "0x40023000", "end": "0x40024000"}}}
        LOG.validate(self.record(), list(range(16)), graphics, list(range(16)), self.exchange(), self.texts(), self.texts())
        for name, value in [("heap_after", 1), ("owner", 0x10010003), ("owner", 1),
                            ("library_pc", 0x4ff20000), ("render_captures", 0), ("captures", 0),
                            ("foreign_rejected", 0), ("irq_rejected", 0), ("forged_rejected", 0),
                            ("observed_used", 32752), ("record_peak", 1025), ("releases", 4),
                            ("client_cycles", 1), ("idle_retained", 0), ("idle_captures", -1), ("idle_progress", 0),
                            ("idle_captures", 5), ("idle_progress", 15)]:
            with self.subTest(name=name, value=value), self.assertRaisesRegex(ValueError, "ownership"):
                LOG.validate({**self.record(), name: value}, list(range(16)), graphics, list(range(16)), self.exchange(), self.texts(), self.texts())
        with self.assertRaisesRegex(ValueError, "hashes"):
            LOG.validate(self.record(), [0] * 16, graphics, list(range(16)), self.exchange(), self.texts(), self.texts())

    def test_transport_requires_real_wait_and_terminal_ack(self):
        graphics = {"functions": {"graphics_font_link_probe": {"start": "0x40023000", "end": "0x40024000"}}}
        for name, value in [("sent", 4), ("received", 4), ("replies", 4), ("waits", 0),
                            ("blocked_ticks", 19), ("idle_runtime", 1), ("stop_ack", 0), ("terminal_gap", 0), ("copied_inputs", 0), ("copied_outputs", 0), ("text_failed", 0), ("queue_bytes", 8192)]:
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "transport"):
                LOG.validate(self.record(), list(range(16)), graphics, list(range(16)), {**self.exchange(), name: value}, self.texts(), self.texts())

    def test_text_reply_never_publishes_missing_glyph_or_wrong_case(self):
        graphics = {"functions": {"graphics_font_link_probe": {"start": "0x40023000", "end": "0x40024000"}}}
        for field, value in [("hash", 123), ("runs", 1), ("outcome", 0), ("id", 7)]:
            bad = self.texts()
            bad[1][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                LOG.validate(self.record(), list(range(16)), graphics, list(range(16)), self.exchange(), bad, self.texts())

    def test_glyph_capacity_and_partial_output_are_rejected_even_with_same_reference(self):
        graphics = {"functions": {"graphics_font_link_probe": {"start": "0x40023000", "end": "0x40024000"}}}
        bad = self.texts()
        bad[0]["glyph_count"] = 17
        bad[0]["glyphs"] *= 17
        with self.assertRaisesRegex(ValueError, "partial native glyph"):
            LOG.validate(self.record(), list(range(16)), graphics, list(range(16)), self.exchange(), bad, bad)
        bad = self.texts()
        bad[2]["glyphs"] = bad[0]["glyphs"]
        bad[2]["glyph_count"] = 1
        with self.assertRaisesRegex(ValueError, "partial native glyph"):
            LOG.validate(self.record(), list(range(16)), graphics, list(range(16)), self.exchange(), bad, bad)

    def test_raster_leases_require_release_and_stale_owner_rejections(self):
        good = dict(zip(LOG.RASTER_FIELDS, [5, 2, 3, 3, 0, 32768, 6, 8, 3]))
        LOG.validate_raster(good)
        for key, value in [("published", 2), ("reclaimed", 2), ("live_charge", 32768), ("held_ticks", 0), ("stale_rejected", 0), ("foreign_rejected", 0)]:
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "raster lease"):
                LOG.validate_raster({**good, key: value})

    def test_surface_requires_reference_pixels_and_untouched_guards(self):
        good = dict(zip(LOG.SURFACE_FIELDS, [3, 33, 5, 3, 6, 65536, 0]))
        texts = [{"id": 5, "surface_hash": 123}, {"id": 6, "surface_hash": 0}]
        reference = {"frames": [{"id": 5, "surface_hash": 123}]}
        LOG.validate_surface(good, texts, reference)
        for key, value in [("clipped", 0), ("guards", 0), ("rejected", 0), ("live_charge", 65536)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOG.validate_surface({**good, key: value}, texts, reference)
        with self.assertRaisesRegex(ValueError, "RGB565"):
            LOG.validate_surface(good, [{"id": 5, "surface_hash": 124}], reference)

    def test_wrapping_requires_complete_metrics_and_reference_pixels(self):
        good = dict(zip(LOG.WRAP_FIELDS, [3, 33, 9, 3, 4, 0]))
        texts = [{"id": 5, "wrap_hash": 123}, {"id": 6, "wrap_hash": 0}]
        reference = {"wrapped": [{"id": 5, "wrap_hash": 123}]}
        LOG.validate_wrap(good, texts, reference)
        for key in LOG.WRAP_FIELDS:
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOG.validate_wrap({**good, key: good[key] + 1}, texts, reference)
        with self.assertRaisesRegex(ValueError, "reference"):
            LOG.validate_wrap(good, [{"id": 5, "wrap_hash": 124}], reference)

    def test_archive_releases_full_charge_after_logging(self):
        good = dict(zip(LOG.ARCHIVE_FIELDS, [2496, 4096, 0, 16022848, 16022848]))
        LOG.validate_archive(good, {"heap_before": 16018752})
        for key in LOG.ARCHIVE_FIELDS:
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOG.validate_archive({**good, key: good[key] + 1}, {"heap_before": 16018752})

    def test_graphics_regions_are_opt_in_and_non_executable(self):
        AUDIT.audit_flash_section(".flash.graphtext", 1, 6, AUDIT.GRAPH_START, 64, allow_graphics=True)
        AUDIT.audit_flash_section(".flash.graphrodata", 1, 50, AUDIT.GRAPH_START + 64, 32, allow_graphics=True)
        with self.assertRaises(ValueError):
            AUDIT.audit_flash_section(".flash.graphtext", 1, 6, AUDIT.GRAPH_START, 64)
        for fields in [(".flash.graphrodata", 1, 3, AUDIT.GRAPH_START, 32),
                       (".flash.graphtext", 1, 7, AUDIT.GRAPH_START, 32)]:
            with self.assertRaises(ValueError):
                AUDIT.audit_flash_section(*fields, allow_graphics=True)
        AUDIT.audit_graphics_sram(".graphics.stack", 8, 3, AUDIT.GRAPH_STACK_LOW, 32768)
        for kind, flags, address, length in [(1, 3, AUDIT.GRAPH_STACK_LOW, 32768),
                                            (8, 7, AUDIT.GRAPH_STACK_LOW, 32768),
                                            (8, 3, AUDIT.GRAPH_STACK_LOW + 16, 32768),
                                            (8, 3, AUDIT.GRAPH_STACK_LOW, 16384)]:
            with self.assertRaises(ValueError):
                AUDIT.audit_graphics_sram(".graphics.stack", kind, flags, address, length)

    def fixture(self):
        start, ram = AUDIT.GRAPH_START, AUDIT.GRAPH_RAM_LOW
        fonts = start + 144
        sections = {".flash.graphtext": (start, bytes(128)), ".flash.graphrodata": (start + 128, bytes(16)),
                    ".flash.graphfonts": (fonts, b"gm"), ".flash.graphpad": (0x40010024, bytes(start - 0x40010024)),
                    ".graphics.data": (ram, bytes(128), 128), ".graphics.bss": (ram + 128, b"", 1024),
                    ".graphics.stack": (AUDIT.GRAPH_STACK_LOW, b"", 32768)}
        symbols = {"__graphics_font_stack_bottom": AUDIT.GRAPH_STACK_LOW, "__graphics_font_stack_top": AUDIT.GRAPH_STACK_HIGH,
                   "__graphics_bss_start": ram + 128, "__graphics_bss_end": ram + 1152, "graphics_result": ram, "graphics_output": ram + 128,
                   "nih_graphics_gothic_start": fonts, "nih_graphics_gothic_end": fonts + 1,
                   "nih_graphics_mincho_start": fonts + 1, "nih_graphics_mincho_end": fonts + 2}
        functions = [("graphics_font_link_probe", start, start + 64), ("nih_gfx_study_malloc", start + 64, start + 128)]
        manifest = {"schema": 1, "allowed_functions": [f[0] for f in functions], "payload_sha256": "fixture",
                    "fonts": [{"family": family, "name": family, "bytes": 1, "sha256": hashlib.sha256(byte).hexdigest()}
                              for family, byte in [("gothic", b"g"), ("mincho", b"m")]]}
        return sections, symbols, {"graphics_result": 124, "graphics_output": 844}, functions, manifest, b"base"

    def test_font_bytes_and_kernel_runtime_namespace_are_bound(self):
        good = self.fixture()
        AUDIT.audit_graphics(*good)
        bad = copy.deepcopy(good)
        bad[0][".flash.graphfonts"] = (bad[0][".flash.graphfonts"][0], b"xx")
        with self.assertRaisesRegex(ValueError, "font bytes"):
            AUDIT.audit_graphics(*bad)
        for name, value, message in [("malloc", AUDIT.GRAPH_START, "unprefixed"),
                                     ("memcpy", AUDIT.GRAPH_START + 4, "redirected")]:
            bad = copy.deepcopy(good)
            bad[1][name] = value
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, message):
                AUDIT.audit_graphics(*bad)


if __name__ == "__main__":
    unittest.main()
