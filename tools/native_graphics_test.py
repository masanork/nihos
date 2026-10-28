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
        return dict(zip(LOG.EXCHANGE_FIELDS, [10, 10, 10, 10, 20, 0, 1, 1, 5, 3, 2, 5, 768]))

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
        good = dict(zip(LOG.SURFACE_FIELDS, [3, 31, 5, 3, 6, 65536, 0]))
        texts = [{"id": 5, "surface_hash": 123}, {"id": 6, "surface_hash": 0}]
        reference = {"frames": [{"id": 5, "surface_hash": 123}]}
        LOG.validate_surface(good, texts, reference)
        for key, value in [("clipped", 0), ("guards", 0), ("rejected", 0), ("live_charge", 65536)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOG.validate_surface({**good, key: value}, texts, reference)
        with self.assertRaisesRegex(ValueError, "RGB565"):
            LOG.validate_surface(good, [{"id": 5, "surface_hash": 124}], reference)

    def test_wrapping_requires_complete_metrics_and_reference_pixels(self):
        good = dict(zip(LOG.WRAP_FIELDS, [3, 31, 8, 2, 3, 0]))
        texts = [{"id": 5, "wrap_hash": 123}, {"id": 6, "wrap_hash": 0}]
        reference = {"frames": [{"id": 5, "wrap_hash": 123}]}
        LOG.validate_wrap(good, texts, reference)
        for key in LOG.WRAP_FIELDS:
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOG.validate_wrap({**good, key: good[key] + 1}, texts, reference)
        with self.assertRaisesRegex(ValueError, "reference"):
            LOG.validate_wrap(good, [{"id": 5, "wrap_hash": 124}], reference)

    def test_kinsoku_requires_native_pixels_and_defect_exposing_control(self):
        good = dict(zip(LOG.POLICY_FIELDS, [3, 28, 3, 9, 4, 0]))
        texts = [{"id": 5, "policy_hash": 123}, {"id": 6, "policy_hash": 0}]
        reference = {"frames": [{"id": 5, "policy_hash": 123, "naive_forbidden_starts": 2, "forbidden_starts": 0, "forbidden_ends": 0}]}
        LOG.validate_policy(good, texts, reference)
        for key in LOG.POLICY_FIELDS:
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOG.validate_policy({**good, key: good[key] + 1}, texts, reference)
        with self.assertRaisesRegex(ValueError, "reference"):
            LOG.validate_policy(good, [{"id": 5, "policy_hash": 124}], reference)
        bad = copy.deepcopy(reference)
        bad["frames"][0]["naive_forbidden_starts"] = 0
        with self.assertRaisesRegex(ValueError, "negative control"):
            LOG.validate_policy(good, texts, bad)

    def test_flash_renderer_requires_in_range_execution_and_real_interrupt_resume(self):
        graphics = {"render": {"start": "0x40b00000", "end": "0x40b00100", "functions": {
            "native_surface.paint": {"start": "0x40b00000", "end": "0x40b00080"},
            "native_surface.draw": {"start": "0x40b00080", "end": "0x40b00100"}}}}
        good = dict(zip(LOG.PLACEMENT_FIELDS, [0x40b00004, 0x40b00084, 3, 124, 6, 100, 3, 2, 0x40b00010]))
        LOG.validate_placement(good, graphics)
        for field, value in (("paint_pc", 0x4ff20000), ("draw_pc", 0x40b00004), ("frames", 2),
                             ("draws", 98), ("context_checks", 5), ("irq_rejected", 0), ("active_ticks", 0),
                             ("flash_ticks", 0), ("flash_ticks", 4), ("trap_pc", 0x4ff20000)):
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                LOG.validate_placement({**good, field: value}, graphics)

    def test_runtime_source_requires_preparation_edit_poison_echo_and_rejections(self):
        names = ("native_font_exchange.stageText", "native_surface.prepare", "native_surface.verify")
        graphics = {"render": {"functions": {name: {"start": hex(0x40b00000 + i * 16), "end": hex(0x40b00010 + i * 16)} for i, name in enumerate(names)}}}
        good = dict(zip(LOG.SOURCE_FIELDS, [0x40b00004, 0x40b00014, 0x40b00024, 5, 10, 5, 1, 5, 5, 3, 3, 3, 3, 3]))
        LOG.validate_source(good, graphics)
        for key in LOG.SOURCE_FIELDS:
            bad = {**good, key: 0}
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOG.validate_source(bad, graphics)

    def test_expected_runtime_edit_is_separate_from_original_native_inputs(self):
        import json
        root = Path(__file__).resolve().parents[1] / "probes/graphics"
        original = json.loads((root / "text_cases.json").read_text())
        edited = json.loads((root / "runtime_text_cases.json").read_text())
        annotations = json.loads((root / "runtime_ruby_cases.json").read_text())
        self.assertEqual(original[0]["body"], "日本語の描画")
        self.assertEqual(edited[0]["body"], "新日本語")
        self.assertEqual(edited[1:], original[1:])
        self.assertEqual([annotations[0][0]["base_start"], annotations[0][0]["base_end"]], [3, 12])

    def test_ruby_requires_parent_movement_reserved_width_pixels_and_control(self):
        record = dict(zip(LOG.RUBY_FIELDS, [3, 2, 2, 1, 19, 2, 8, 0, 172, 320]))
        texts = [{"id": 5, "ruby_hash": 123}, {"id": 6, "ruby_hash": 0}]
        reference = {"frames": [{"id": 5, "ruby_hash": 123, "groups": 2, "moved": 2, "control_hash": 456}]}
        LOG.validate_ruby(record, texts, reference)
        for field in LOG.RUBY_FIELDS:
            with self.subTest(field=field), self.assertRaises(ValueError):
                LOG.validate_ruby({**record, field: record[field] + 1}, texts, reference)
        with self.assertRaisesRegex(ValueError, "reference"):
            LOG.validate_ruby(record, [{"id": 5, "ruby_hash": 456}], reference)
        bad = copy.deepcopy(reference)
        bad["frames"][0]["control_hash"] = 123
        with self.assertRaisesRegex(ValueError, "control"):
            LOG.validate_ruby(record, texts, bad)

    def test_archive_releases_full_charge_after_logging(self):
        good = dict(zip(LOG.ARCHIVE_FIELDS, [4496, 8192, 0, 16022848, 16022848]))
        LOG.validate_archive(good, {"heap_before": 16014656})
        for key in LOG.ARCHIVE_FIELDS:
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOG.validate_archive({**good, key: good[key] + 1}, {"heap_before": 16014656})

    def test_queue_lifetime_and_payload_addresses_are_required(self):
        good = dict(zip(LOG.QUEUE_FIELDS, [1, 768, 1160, 2, 2, 2, 0, 3, 0x4ff21000, 0x4ff21180, 0x48090000, 0x48090100]))
        image = {"memory": {"origin": "0x4ff20000"}, "heap": {"start": "0x4ff30000"}, "graphics": {"queue_metadata": {
            "requests": {"start": "0x4ff21000", "end": "0x4ff21180"}, "replies": {"start": "0x4ff21180", "end": "0x4ff21300"}}}}
        heap = {"start": 0x48000000, "metadata": 0x80000, "end": 0x49000000}
        LOG.validate_queues(good, image, heap)
        for key in LOG.QUEUE_FIELDS:
            value = 1 if key == "live_payloads" else 0
            with self.subTest(key=key), self.assertRaises(ValueError):
                LOG.validate_queues({**good, key: value}, image, heap)
        with self.assertRaisesRegex(ValueError, "disjoint"):
            LOG.validate_queues({**good, "reply_payload": good["request_payload"]}, image, heap)

    def test_queue_metadata_cannot_move_to_psram_or_grow_silently(self):
        for name in ("native_font_exchange.requests", "native_font_exchange.replies"):
            bad = copy.deepcopy(self.fixture())
            bad[1][name] = 0x48090000
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "queue metadata"):
                AUDIT.audit_graphics(*bad)
            bad = copy.deepcopy(self.fixture())
            bad[2][name] = 512
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "queue metadata"):
                AUDIT.audit_graphics(*bad)

    def test_graphics_regions_are_opt_in_and_non_executable(self):
        AUDIT.audit_flash_section(".flash.graphtext", 1, 6, AUDIT.GRAPH_START, 64, allow_graphics=True)
        AUDIT.audit_flash_section(".flash.graphrender", 1, 6, AUDIT.GRAPH_START + 128, 16, allow_graphics=True)
        with self.assertRaises(ValueError):
            AUDIT.audit_flash_section(".flash.graphrender", 1, 6, AUDIT.GRAPH_START + 128, 16)
        AUDIT.audit_flash_section(".flash.graphrodata", 1, 50, AUDIT.GRAPH_START + 64, 32, allow_graphics=True)
        with self.assertRaises(ValueError):
            AUDIT.audit_flash_section(".flash.graphtext", 1, 6, AUDIT.GRAPH_START, 64)
        for fields in [(".flash.graphrodata", 1, 3, AUDIT.GRAPH_START, 32),
                       (".flash.graphtext", 1, 7, AUDIT.GRAPH_START, 32),
                       (".flash.graphrender", 1, 7, AUDIT.GRAPH_START, 32),
                       (".flash.graphrender", 1, 2, AUDIT.GRAPH_START, 32)]:
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
        render = fonts + 4
        sections = {".flash.graphtext": (start, bytes(128)), ".flash.graphrodata": (start + 128, bytes(16)),
                    ".flash.graphfonts": (fonts, b"gm"), ".flash.graphrender": (render, bytes(8 * len(AUDIT.RENDER_FUNCTIONS))), ".flash.graphpad": (0x40010024, bytes(start - 0x40010024)),
                    ".graphics.data": (ram, bytes(128), 128), ".graphics.bss": (ram + 128, b"", 1024),
                    ".graphics.stack": (AUDIT.GRAPH_STACK_LOW, b"", 32768)}
        symbols = {"__graphics_font_stack_bottom": AUDIT.GRAPH_STACK_LOW, "__graphics_font_stack_top": AUDIT.GRAPH_STACK_HIGH,
                   "__graphics_bss_start": ram + 128, "__graphics_bss_end": ram + 1152, "graphics_result": ram, "graphics_output": ram + 128, "native_font_exchange.requests": AUDIT.SRAM_LOW + 0x400, "native_font_exchange.replies": AUDIT.SRAM_LOW + 0x580,
                   "nih_graphics_gothic_start": fonts, "nih_graphics_gothic_end": fonts + 1,
                   "nih_graphics_mincho_start": fonts + 1, "nih_graphics_mincho_end": fonts + 2,
                   "__flash_render_start": render, "__flash_render_end": render + 8 * len(AUDIT.RENDER_FUNCTIONS), "__flash_graphics_end": render + 8 * len(AUDIT.RENDER_FUNCTIONS)}
        functions = [("graphics_font_link_probe", start, start + 64), ("nih_gfx_study_malloc", start + 64, start + 128)]
        manifest = {"schema": 1, "allowed_functions": [f[0] for f in functions], "payload_sha256": "fixture",
                    "fonts": [{"family": family, "name": family, "bytes": 1, "sha256": hashlib.sha256(byte).hexdigest()}
                              for family, byte in [("gothic", b"g"), ("mincho", b"m")]]}
        functions += [(name, render + i * 8, render + i * 8 + 8) for i, name in enumerate(sorted(AUDIT.RENDER_FUNCTIONS))]
        functions += [(name, AUDIT.SRAM_LOW + i * 16, AUDIT.SRAM_LOW + i * 16 + 8) for i, name in enumerate(sorted(AUDIT.RENDER_RESIDENT))]
        return sections, symbols, {"graphics_result": 124, "graphics_output": 844, "native_font_exchange.requests": 384, "native_font_exchange.replies": 384}, functions, manifest, b"base"

    def test_rendering_flash_accepts_only_whitelisted_functions_and_retains_critical_sram_code(self):
        good = self.fixture()
        report, _, _ = AUDIT.audit_graphics(*good)
        self.assertEqual(set(report["render"]["functions"]), AUDIT.RENDER_FUNCTIONS)
        for mutate in ("missing", "extra", "renamed", "overlap", "overrun", "resident"):
            bad = copy.deepcopy(good)
            functions = bad[3]
            index = next(i for i, f in enumerate(functions) if f[0] == "native_surface.paint")
            name, low, high = functions[index]
            if mutate == "missing":
                functions.pop(index)
            elif mutate == "extra":
                functions.append(("unapproved", low, high))
            elif mutate == "renamed":
                functions[index] = ("native_surface.unknown", low, high)
            elif mutate == "overlap":
                functions[index] = (name, low, high + 2)
            elif mutate == "overrun":
                functions[index] = (name, low, high + 32)
            else:
                index = next(i for i, f in enumerate(functions) if f[0] == "heap.allocTask")
                functions[index] = ("heap.allocTask", 0x40018000, 0x40018008)
            with self.subTest(mutate=mutate), self.assertRaises(ValueError):
                AUDIT.audit_graphics(*bad)

    def test_rendering_flash_must_remain_contiguous_and_bound_to_linker_symbols(self):
        good = self.fixture()
        for name in ("__flash_render_start", "__flash_render_end", "__flash_graphics_end"):
            bad = copy.deepcopy(good)
            bad[1][name] += 4
            with self.subTest(name=name), self.assertRaisesRegex(ValueError, "symbols"):
                AUDIT.audit_graphics(*bad)
        bad = copy.deepcopy(good)
        low, data = bad[0][".flash.graphrender"]
        bad[0][".flash.graphrender"] = (low + 4, data)
        with self.assertRaisesRegex(ValueError, "noncontiguous"):
            AUDIT.audit_graphics(*bad)

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
