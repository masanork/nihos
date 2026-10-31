"""Instruction-boundary checks for the restricted RV32IMAF/C native audit."""
import importlib.util
from pathlib import Path
import unittest
import struct
import hashlib

SPEC = importlib.util.spec_from_file_location("native_image", Path(__file__).with_name("check-native-image.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class NativeInstructionTests(unittest.TestCase):
    def test_reader_rom_can_expand_without_expanding_executable_flash_window(self):
        MODULE.audit_flash_section('.flash.xyrodata',1,2,0x40080000,0x280000,allow_xy=True)
        for name, flags, address, size in [
            ('.flash.xyrodata',6,0x40080000,32),
            ('.flash.xyrodata',3,0x40080000,32),
            ('.flash.xyrodata',2,0x403ffff0,32),
            ('.flash.xytext',6,0x40060000,0x60010),
        ]:
            with self.subTest(name=name,flags=flags), self.assertRaises(ValueError):
                MODULE.audit_flash_section(name,1,flags,address,size,allow_xy=True)

    def test_learning_flash_methods_remain_explicit_foreground_only(self):
        for name in ('xy.learning_session.Session.run', 'learning_session.Session.resetVm',
                     'learning_catalog.Pack.onPage', 'xy.learning_catalog.Pack.init',
                     'learning_view.render__func_2', 'learning_view.label__func_3',
                     'learning_catalog.Pack.styleOnPage', 'viewport_layout.layoutStyledParagraph__func_1',
                     'viewport_layout.shapeStyledRun__func_2',
                     'nih_xy_render_learning', 'native_render_entry.nih_xy_render_learning',
                     'xy.scratch.Model.touch', 'xy.document.Document(4096,256,2048,1,64).undo'):
            with self.subTest(name=name): self.assertTrue(MODULE.xy_function(name))
        for name in ('xy.learning_session.Session.arbitrary', 'learning_catalog.Pack.arbitrary',
                     'learning_view.render__func_bad', 'learning_view.render__func_2.extra',
                     'learning_view.irq__func_1', 'viewport_layout.layoutStyledParagraph__func_bad',
                     'viewport_layout.shapeStyledRun__func_2.extra', 'learning_session.Host.arbitrary', 'xy.document.Document(4096,256,2048,1,64).arbitrary',
                     'xy.document.Document(8192,256,2048,1,64).undo'):
            with self.subTest(name=name): self.assertFalse(MODULE.xy_function(name))

    def test_native_render_capacity_is_exactly_the_embedded_budget(self):
        self.assertTrue(MODULE.xy_function('viewport_layout.layoutParagraph__func_1'))
        self.assertTrue(MODULE.xy_function('render_session.SizedSession(512).render'))
        self.assertTrue(MODULE.xy_function('render_session.SizedSession(512).renderInto__func_0'))
        self.assertTrue(MODULE.xy_function('render_session.SizedSession(1024).render'))
        self.assertFalse(MODULE.xy_function('render_session.SizedSession(2048).render'))
        self.assertTrue(MODULE.xy_function('render_session.SizedSession(1024).renderInto__func_0'))
        self.assertFalse(MODULE.xy_function('render_session.SizedSession(2048).renderInto__func_0'))

    def test_xy_foreground_requires_exact_functions_and_readonly_bounded_sections(self):
        start = 0x40060000
        functions = [('xy.scheme_runtime.Runtime.evaluate__func_1', start, start + 16),
                     ('xy.scheme_runtime.Runtime.collect', start + 16, start + 32)]
        self.assertEqual(len(MODULE.audit_xy_functions(functions, (start, start + 32))), 2)
        handoff = functions + [('diagnostic_ui.beginSession__func_1', start + 32, start + 48)]
        self.assertEqual(len(MODULE.audit_xy_functions(handoff, (start, start + 48))), 3)
        for name in ('diagnostic_ui.beginSession__func_bad', 'diagnostic_ui.beginSession__func_1.extra', 'diagnostic_ui.arbitrary__func_1'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                MODULE.audit_xy_functions(handoff[:-1] + [(name, start + 32, start + 48)], (start, start + 48))
        for name, flags, address in (('.flash.xytext', 6, start), ('.flash.xyrodata', 2, start + 32)):
            MODULE.audit_flash_section(name, 1, flags, address, 16, allow_xy=True)
            for kind, changed, permitted in ((1, flags, False), (1, 7, True), (8, flags, True)):
                with self.assertRaises(ValueError):
                    MODULE.audit_flash_section(name, kind, changed, address, 16, allow_xy=permitted)
        for changed in ([('irq.arbitrary', *functions[0][1:])] + functions[1:],
                        [('xy.scheme_runtime.Runtime.unapproved', *functions[0][1:])] + functions[1:],
                        [functions[0], (functions[1][0], start + 48, start + 64)], functions[:1]):
            with self.assertRaises(ValueError):
                MODULE.audit_xy_functions(changed, (start, start + 64))
        with self.assertRaises(ValueError):
            MODULE.audit_flash_section('.flash.xytext', 1, 6, start - 16, 32, allow_xy=True)

    def test_xy_renderer_aliases_and_expanded_readonly_extent_are_checked(self):
        start = 0x40060000
        functions = [('nih_xy_render', start, start + 16),
                     ('native_render_entry.nih_xy_render', start, start + 16),
                     ('xy.scheme_runtime.Runtime.evaluate__func_1', start + 16, start + 32),
                     ('xy.scheme_runtime.Runtime.collect', start + 32, start + 48)]
        MODULE.audit_xy_functions(functions, (start, start + 48))
        with self.assertRaises(ValueError):
            MODULE.audit_xy_functions(functions + [('irq.unapproved', start, start + 16)], (start, start + 48))
        MODULE.audit_flash_section('.flash.xyrodata', 1, 2, 0x40080000, 32, allow_xy=True)
        with self.assertRaises(ValueError):
            MODULE.audit_flash_section('.flash.xyrodata', 1, 2, 0x403ffff0, 32, allow_xy=True)

    def test_normal_filesystem_sections_require_explicit_profile_and_permissions(self):
        cases = (('.flash.fstext', 0x40020000, 128, 6),
                 ('.flash.fsrodata', 0x40020080, 128, 2),
                 ('.flash.fspad', 0x4001fff0, 16, 2))
        for name, start, size, flags in cases:
            MODULE.audit_flash_section(name, 1, flags, start, size, allow_fs=True)
            with self.assertRaises(ValueError):
                MODULE.audit_flash_section(name, 1, flags, start, size)
            for kind, changed in ((8, flags), (1, 7)):
                with self.assertRaises(ValueError):
                    MODULE.audit_flash_section(name, kind, changed, start, size, allow_fs=True)
        with self.assertRaises(ValueError):
            MODULE.audit_flash_section('.flash.fstext', 1, 6, 0x4001ff00, 256, allow_fs=True)
        boot = [('psram.probe', 0x40000120, 0x40000920), ('psram_memory.prepare__func_1', 0x40000920, 0x40001120)]
        fs = [('nih_normal_fs_task', 0x40020000, 0x40020100)]
        MODULE.audit_boot_functions(boot + fs, 0x40000120, 0x40001120, 0x4ff00000, 0x4ff28000,
                                   fs_span=(0x40020000, 0x40020100), fs_functions=['nih_normal_fs_task'])
        with self.assertRaises(ValueError):
            MODULE.audit_boot_functions(boot + fs, 0x40000120, 0x40001120, 0x4ff00000, 0x4ff28000,
                                       fs_span=(0x40020000, 0x40020100))

    def test_network_time_code_has_exact_rx_allowlist_and_bounded_extent(self):
        start = 0x40004000
        names = sorted(MODULE.TIME_FUNCTIONS) + [prefix + '__func_7' for prefix in sorted(MODULE.TIME_GENERIC)]
        functions = [(name, start + i*16, start + (i+1)*16) for i, name in enumerate(names)]
        span = (start, start + len(names)*16)
        self.assertEqual(len(MODULE.audit_time_functions(functions, span)), len(names))
        MODULE.audit_flash_section('.flash.time', 1, 6, start, span[1]-start, allow_time=True)
        for changed in (functions[:-1], [('irq.unapproved', *functions[0][1:])] + functions[1:],
                        [(functions[0][0], start, start+20)] + functions[1:]):
            with self.assertRaises(ValueError):
                MODULE.audit_time_functions(changed, span)
        for kind, flags, allowed in ((1, 6, False), (8, 6, True), (1, 7, True), (1, 2, True)):
            with self.assertRaises(ValueError):
                MODULE.audit_flash_section('.flash.time', kind, flags, start, 64, allow_time=allowed)

    def test_device_code_requires_exact_allowlist_rx_extent_and_explicit_profile(self):
        first = 0x40002000
        names = sorted(MODULE.DEVICE_FUNCTIONS) + ['audio_probe.poll__func_1', 'microphone_probe.poll__func_2', 'rs485_probe.poll__func_3']
        functions = [(name, first + i * 16, first + (i + 1) * 16) for i, name in enumerate(names)]
        span = (first, first + len(names) * 16)
        MODULE.audit_flash_section('.flash.devices', 1, 6, first, span[1] - first, allow_devices=True)
        self.assertEqual(len(MODULE.audit_device_functions(functions, span)), len(names))
        optional = sorted(MODULE.CAMERA_FOREGROUND_FUNCTIONS) + ['diagnostic_ui.input__func_16', 'diagnostic_ui.poll__func_17', 'diagnostic_ui.sessionKey__func_18']
        extended = functions + [(name, span[1] + i * 16, span[1] + (i + 1) * 16) for i, name in enumerate(optional)]
        self.assertEqual(len(MODULE.audit_device_functions(extended, (first, extended[-1][2]))), len(extended))
        for name in ('diagnostic_ui.input__func_bad', 'diagnostic_ui.input__func_16.extra', 'diagnostic_ui.poll__func_bad', 'diagnostic_ui.sessionKey__func_18.extra', 'board_devices.arbitrary'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                MODULE.audit_device_functions(extended[:-1] + [(name, *extended[-1][1:])], (first, extended[-1][2]))
        for kind, flags, allowed in ((1, 6, False), (8, 6, True), (1, 7, True), (1, 2, True)):
            with self.assertRaises(ValueError):
                MODULE.audit_flash_section('.flash.devices', kind, flags, first, 64, allow_devices=allowed)
        for changed in (functions[:-1], [('arbitrary.run', *functions[0][1:])] + functions[1:],
                        [(functions[0][0], first, first + 20)] + functions[1:]):
            with self.assertRaises(ValueError):
                MODULE.audit_device_functions(changed, span)
        boot = [('psram.probe', 0x40000120, 0x40000920), ('psram_memory.prepare__func_1', 0x40000920, 0x40001120)]
        MODULE.audit_boot_functions(boot + functions, 0x40000120, 0x40001120, 0x4ff00000, 0x4ff28000, device_span=span)
        with self.assertRaises(ValueError):
            MODULE.audit_boot_functions(boot + functions, 0x40000120, 0x40001120, 0x4ff00000, 0x4ff28000)

    def test_automatic_card_flash_functions_require_explicit_profile_and_bounded_span(self):
        boot = [('psram.probe', 0x40000120, 0x40000920),
                ('psram_memory.prepare__func_1', 0x40000920, 0x40001120)]
        allowed = ('card_auto.run', 'notice_build', 'nih_display_notice_publish', 'nih_display_scanout_begin',
                   'display_runtime.presentNotice', 'keypad_display.publishNotice', 'card.license.Parser(.flash.photo).decode',
                   'card.service.ServiceType(true,.flash.photo).take',
                   'card.wire_policy.PolicyType(true).allow')
        for name in allowed:
            functions = boot + [(name, 0x40090000, 0x40090100)]
            MODULE.audit_boot_functions(functions, 0x40000120, 0x40001120,
                0x4ff00000, 0x4ff28000, photo_span=(0x40090000, 0x40090100), automatic_cards=True)
            with self.subTest(name=name), self.assertRaises(ValueError):
                MODULE.audit_boot_functions(functions, 0x40000120, 0x40001120,
                    0x4ff00000, 0x4ff28000, photo_span=(0x40090000, 0x40090100))
        for name, stop in (('card_auto.run', 0x40090104), ('arbitrary.run', 0x40090100),
                           ('card.service.ServiceType(false,null).take', 0x40090100)):
            with self.subTest(name=name, stop=stop), self.assertRaises(ValueError):
                MODULE.audit_boot_functions(boot + [(name, 0x40090000, stop)],
                    0x40000120, 0x40001120, 0x4ff00000, 0x4ff28000,
                    photo_span=(0x40090000, 0x40090100), automatic_cards=True)

    def test_keypad_pools_are_opt_in_exact_rw_nonexecuting_nobits(self):
        for name, (address, size) in MODULE.UI_POOLS.items():
            MODULE.audit_ui_pool(name, 8, 3, address, size, True)
            for kind, flags, origin, length, allowed in ((1, 3, address, size, True),
                    (8, 7, address, size, True), (8, 2, address, size, True),
                    (8, 3, address + 64, size, True), (8, 3, address, size - 64, True),
                    (8, 3, address, size, False)):
                with self.subTest(name=name, flags=flags), self.assertRaises(ValueError):
                    MODULE.audit_ui_pool(name, kind, flags, origin, length, allowed)

    def test_base_free_sram_excludes_primary_stack_and_font_sections(self):
        symbols = {'__service_sram0_start': 0x4ff48000, '__service_sram0_end': 0x4ff60000,
                   '__service_sram1_start': 0x4ff80000, '__service_sram1_end': 0x4ff9f000}
        occupied = [{'address': '0x4ff20000', 'bytes': 160 * 1024},
                    {'address': '0x4ff60000', 'bytes': 56 * 1024},
                    {'address': '0x4ff6e000', 'bytes': 32 * 1024},
                    {'address': '0x4ff78000', 'bytes': 32 * 1024}]
        self.assertEqual(len(MODULE.audit_service_sram(symbols, 0x4ff48000, occupied)), 2)
        for changes in ({'__service_sram0_start': 0x4ff40000}, {'__service_sram1_start': 0x4ff70000},
                        {'__service_sram1_end': 0x4ffa0000}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                MODULE.audit_service_sram({**symbols, **changes}, 0x4ff48000, occupied)

    def test_keypad_assets_require_readonly_flash_and_matching_manifest(self):
        for name, address, size in (('.flash.ui', 0x40020000, 128), ('.flash.uipad', 0x4001fff0, 16)):
            for flags in (2, 50):
                MODULE.audit_flash_section(name, 1, flags, address, size, allow_ui=True)
            for kind, flags, allowed in ((8, 2, True), (1, 3, True), (1, 6, True), (1, 2, False)):
                with self.subTest(name=name, flags=flags), self.assertRaises(ValueError):
                    MODULE.audit_flash_section(name, kind, flags, address, size, allow_ui=allowed)
        start, data = 0x40020000, bytes(range(128))
        symbols = {'__keypad_plan_start': start, '__keypad_plan_end': start + 64,
                   '__keypad_atlas_start': start + 64, '__keypad_atlas_end': start + 128}
        manifest = {}
        for role, raw in (('plan', data[:64]), ('atlas', data[64:])):
            manifest[role + '_bytes'] = 64
            manifest[role + '_sha256'] = hashlib.sha256(raw).hexdigest()
        MODULE.audit_ui_assets(start, data, symbols, manifest)
        for changed in (data[:-1], b'x' + data[1:], data[:64] + b'x' + data[65:]):
            with self.assertRaises(ValueError):
                MODULE.audit_ui_assets(start, changed, symbols, manifest)
        with self.assertRaises(ValueError):
            MODULE.audit_ui_assets(start, data, {**symbols, '__keypad_atlas_start': start + 65}, manifest)

    def test_card_foreground_is_opt_in_rx_and_has_only_named_functions(self):
        MODULE.audit_flash_section('.flash.card', 1, 6, 0x40002000, 128, allow_ui=True)
        for kind, flags, allowed in ((1, 6, False), (1, 7, True), (1, 2, True), (8, 6, True)):
            with self.assertRaises(ValueError):
                MODULE.audit_flash_section('.flash.card', kind, flags, 0x40002000, 128, allow_ui=allowed)
        functions = [('psram.probe', 0x40000120, 0x40000920),
                     ('psram_memory.prepare__func_1', 0x40000920, 0x40001120),
                     ('card_read.run__func_2', 0x40002000, 0x40002080)]
        MODULE.audit_boot_functions(functions, 0x40000120, 0x40001120, 0x4ff00000, 0x4ff28000,
                                    card_span=(0x40002000, 0x40002080), card_functions=('card_read.run',))
        for changed in (functions[:-1] + [('unexpected', 0x40002000, 0x40002080)],
                        functions[:-1] + [('card_read.run__func_2', 0x40002000, 0x40002084)]):
            with self.assertRaises(ValueError):
                MODULE.audit_boot_functions(changed, 0x40000120, 0x40001120, 0x4ff00000, 0x4ff28000,
                                            card_span=(0x40002000, 0x40002080), card_functions=('card_read.run',))
        with self.assertRaises(ValueError):
            MODULE.audit_boot_functions(functions, 0x40000120, 0x40001120, 0x4ff00000, 0x4ff28000)

    def test_high_banks_reject_loadable_executable_shifted_and_emulator_layouts(self):
        for name, (low, high) in MODULE.HIGH_BANKS.items():
            MODULE.audit_high_section(name, 8, 3, low, high-low, 'device')
            for kind, flags, address, size, profile in ((1,3,low,high-low,'device'),
                    (8,7,low,high-low,'device'), (8,2,low,high-low,'device'),
                    (8,3,low+4096,high-low,'device'), (8,3,low,high-low-4096,'device'),
                    (8,3,low,high-low,'emulator')):
                with self.subTest(name=name, profile=profile, flags=flags), self.assertRaises(ValueError):
                    MODULE.audit_high_section(name,kind,flags,address,size,profile)

    def test_high_bank_pair_and_linker_symbols_are_required_together(self):
        symbols = {}
        sections = []
        for name,(low,high) in MODULE.HIGH_BANKS.items():
            symbols['__'+name[1:]+'_start'] = low
            symbols['__'+name[1:]+'_end'] = high
            sections.append({'name':name,'address':hex(low),'bytes':high-low})
        self.assertEqual(MODULE.audit_high_layout(symbols,sections)['heap_bytes'],208*1024)
        for bad in ([],sections[:1],sections+sections):
            with self.assertRaises(ValueError): MODULE.audit_high_layout(symbols,bad)
        for key in symbols:
            with self.assertRaises(ValueError): MODULE.audit_high_layout({**symbols,key:0},sections)

    def test_loader_collision_checks_include_both_high_banks(self):
        report = {'memory':{'origin':'0x4ff00000','end':'0x4ff28000','regions':[
            {'name':name,'origin':hex(low),'end':hex(high)} for name,(low,high) in MODULE.HIGH_BANKS.items()]}}
        for low,high in MODULE.HIGH_BANKS.values():
            for address in (low-4,low,high-4):
                for kind in (1,8):
                    with self.subTest(address=hex(address),kind=kind),self.assertRaises(ValueError):
                        MODULE.audit_loader(report,loader_elf([(kind,2,address,16)]))

    def test_stack_symbols_array_and_section_have_exact_reservations(self):
        base = 0x4ff60000
        symbols = {"__stacks_start": base, "__stacks_end": base + 57344,
                   "__task_stacks_start": base + 32768, "__task_stacks_end": base + 57344,
                   "native_tasks.stacks": base + 32768}
        for prefix, offset in (("stack0", 0), ("stack1", 8192), ("irq_stack0", 16384), ("irq_stack1", 24576)):
            symbols["__" + prefix + "_bottom"] = base + offset
            symbols["__" + prefix + "_top"] = base + offset + 8192
        sizes = {"native_tasks.stacks": 24576}
        sections = [{"name": ".stacks", "address": hex(base), "bytes": 57344}]
        self.assertEqual(MODULE.audit_stack_layout(symbols, sizes, sections)["bytes"], 57344)
        for name in symbols:
            with self.subTest(symbol=name), self.assertRaisesRegex(ValueError, "stack"):
                MODULE.audit_stack_layout({**symbols, name: symbols[name] + 16}, sizes, sections)
        with self.assertRaisesRegex(ValueError, "array"):
            MODULE.audit_stack_layout(symbols, {"native_tasks.stacks": 16384}, sections)
        for bad in ([], sections + sections, [{**sections[0], "bytes": 57328}]):
            with self.assertRaisesRegex(ValueError, "stack"):
                MODULE.audit_stack_layout(symbols, sizes, bad)

    def test_task_side_trap_reserve_is_accounted_before_irq_stack_switch(self):
        base = 0x4ff60000
        symbols = {"__stacks_start": base, "__stacks_end": base + 57344,
                   "__task_stacks_start": base + 32768, "__task_stacks_end": base + 57344,
                   "native_tasks.stacks": base + 32768, "nih_native_task_context_bytes": 128}
        for prefix, offset in (("stack0", 0), ("stack1", 8192), ("irq_stack0", 16384), ("irq_stack1", 24576)):
            symbols["__" + prefix + "_bottom"] = base + offset
            symbols["__" + prefix + "_top"] = base + offset + 8192
        sizes = {"native_tasks.stacks": 24576}
        sections = [{"name": ".stacks", "address": hex(base), "bytes": 57344}]
        result = MODULE.audit_stack_layout(symbols, sizes, sections)
        self.assertEqual(result['ordinary_sp_budget_bytes'], 4096 - 16 - 128)
        for value in (0, 64, 129, 256):
            with self.assertRaises(ValueError):
                MODULE.audit_stack_layout({**symbols, 'nih_native_task_context_bytes': value}, sizes, sections)

    def test_stack_bank_is_non_executable_unloaded_and_bounded(self):
        MODULE.audit_stack_section(8, 3, 0x4ff60000, 57344)
        for values in ((1, 3, 0x4ff60000, 57344), (8, 7, 0x4ff60000, 57344),
                       (8, 2, 0x4ff60000, 57344), (8, 3, 0x4ff60010, 57344), (8, 3, 0x4ff60000, 32768)):
            with self.subTest(values=values), self.assertRaisesRegex(ValueError, "stack"):
                MODULE.audit_stack_section(*values)

    def test_loader_audits_both_regions_while_allowing_the_reserved_hole(self):
        report = {"memory": {"origin": "0x4ff00000", "end": "0x4ff28000", "regions": [
            {"name": "resident", "origin": "0x4ff00000", "end": "0x4ff28000"},
            {"name": "stacks", "origin": "0x4ff60000", "end": "0x4ff6e000"}]}}
        result = MODULE.audit_loader(report, loader_elf([(1, 2, 0x4ff2abd0, 8192)]))
        self.assertEqual([gap["name"] for gap in result["regions_checked"]], ["resident", "stacks"])
        self.assertIsNone(result["regions_checked"][1]["gap_above"])
        self.assertGreater(result["regions_checked"][1]["gap_below"], 0)

    def test_loader_collisions_with_stack_bank_include_both_edges_and_nobits(self):
        report = {"memory": {"origin": "0x4ff20000", "end": "0x4ff48000", "regions": [
            {"name": "resident", "origin": "0x4ff20000", "end": "0x4ff48000"},
            {"name": "stacks", "origin": "0x4ff60000", "end": "0x4ff6e000"}]}}
        for kind in (1, 8):
            for address in (0x4ff5fffc, 0x4ff68000, 0x4ff6dffc):
                with self.subTest(kind=kind, address=hex(address)), self.assertRaisesRegex(ValueError, "stacks"):
                    MODULE.audit_loader(report, loader_elf([(1, 2, 0x4ffac2c0, 64), (kind, 2, address, 16)]))

    def test_flash_boot_code_requires_execute_read_permissions_and_one_page(self):
        MODULE.audit_flash_section(".flash.boot", 1, 6, 0x40000120, 65248)
        for kind, flags, address, size in ((8, 6, 0x40000120, 64), (1, 2, 0x40000120, 64),
                                            (1, 7, 0x40000120, 64), (1, 6, 0x40000124, 64),
                                            (1, 6, 0x40000120, 0), (1, 6, 0x40000120, 65249)):
            with self.subTest(kind=kind, flags=flags, size=size), self.assertRaises(ValueError):
                MODULE.audit_flash_section(".flash.boot", kind, flags, address, size)

    def test_only_two_named_boot_functions_may_leave_sram(self):
        functions = [("resident", 0x4ff20000, 0x4ff20100), ("nih_rom_putc", 0x4fc00054, 0x4fc00058),
                     ("psram.probe", 0x40000120, 0x40000920),
                     ("psram_memory.prepare__func_43", 0x40000920, 0x40001120)]
        def check(values):
            return MODULE.audit_boot_functions(values, 0x40000120, 0x40001120, 0x4ff20000, 0x4ff48000)
        self.assertEqual(set(check(functions)), {"probe", "mapping"})
        cases = [functions[:3], functions + [("unexpected", 0x40000140, 0x40000180)],
                 functions + [("psram_memory.prepare__func_44", 0x40000920, 0x40001120)],
                 functions[:2] + [("psram.probe", 0x40000120, 0x40000922), functions[3]],
                 functions[:2] + [("psram.probe", 0x40000122, 0x40000920), functions[3]],
                 functions[:2] + [("psram.probe", 0x40000120, 0x40010002), functions[3]],
                 functions + [("oversized_resident", 0x4ff47ffe, 0x4ff48002)]]
        for values in cases:
            with self.subTest(functions=values), self.assertRaises(ValueError):
                check(values)

    def test_pmp_flash_is_an_exact_rx_allowlist_on_the_boot_page(self):
        start = 0x40001200
        names = sorted(MODULE.PMP_FLASH_FUNCTIONS)
        functions = []
        address = start
        for name in names:
            functions.append((name, address, address + 32))
            address += 32
        end = address
        self.assertEqual(set(MODULE.audit_pmp_flash(functions, (start, end))), set(names))
        # An unused helper may be discarded. A kept helper must stay in this extent.
        self.assertEqual(set(MODULE.audit_pmp_flash(functions[:-1], (start, end - 32))), set(names[:-1]))
        boot = [("resident", 0x4ff20000, 0x4ff20100), ("nih_rom_putc", 0x4fc00054, 0x4fc00058),
                ("psram.probe", 0x40000120, 0x40000920),
                ("psram_memory.prepare__func_43", 0x40000920, 0x40001120)]
        self.assertEqual(set(MODULE.audit_boot_functions(boot + functions, 0x40000120, 0x40001120, 0x4ff20000, 0x4ff48000, pmp_span=(start, end))),
                         {"probe", "mapping"})
        with self.assertRaises(ValueError):
            MODULE.audit_pmp_flash(functions[:-1] + [(names[-1], 0x4ff30000, 0x4ff30020)], (start, end - 32))
        with self.assertRaises(ValueError):
            MODULE.audit_pmp_flash(functions + [("pmp.extra", end, end + 16)], (start, end + 16))
        with self.assertRaises(ValueError):
            MODULE.audit_boot_functions(boot + functions, 0x40000120, 0x40001120, 0x4ff20000, 0x4ff48000)
        MODULE.audit_flash_section(".flash.pmp", 1, 6, start, end - start)
        for kind, flags, where, size in ((8, 6, start, 64), (1, 2, start, 64), (1, 6, 0x40000120, 64), (1, 6, start, 0)):
            with self.subTest(kind=kind, flags=flags, address=where, size=size), self.assertRaises(ValueError):
                MODULE.audit_flash_section(".flash.pmp", kind, flags, where, size)

    def test_user_probe_flash_is_an_optional_aligned_rx_span(self):
        start = 0x40002000
        names = sorted(MODULE.USER_PROBE_FUNCTIONS)
        functions = []
        address = start
        for name in names:
            functions.append((name, address, address + 64))
            address += 64
        end = start + 256
        MODULE.audit_flash_section(".flash.user", 1, 6, start, end - start)
        boot = [("resident", 0x4ff20000, 0x4ff20100), ("nih_rom_putc", 0x4fc00054, 0x4fc00058),
                ("psram.probe", 0x40000120, 0x40000920),
                ("psram_memory.prepare__func_43", 0x40000920, 0x40001120)]
        self.assertEqual(set(MODULE.audit_boot_functions(boot + functions, 0x40000120, 0x40001120, 0x4ff20000, 0x4ff48000, user_span=(start, end))),
                         {"probe", "mapping"})
        with self.assertRaisesRegex(ValueError, "unapproved user probe"):
            MODULE.audit_boot_functions(boot + functions + [("nih_user_probe_extra", start + 128, start + 160)],
                                        0x40000120, 0x40001120, 0x4ff20000, 0x4ff48000, user_span=(start, end))
        with self.assertRaisesRegex(ValueError, "unapproved Flash function"):
            MODULE.audit_boot_functions(boot + functions, 0x40000120, 0x40001120, 0x4ff20000, 0x4ff48000)
        for kind, flags, where, size in ((8, 6, start, 128), (1, 7, start, 128), (1, 6, start + 16, 128),
                                         (1, 6, start, 64), (1, 6, 0x40000120, 128)):
            with self.subTest(kind=kind, flags=flags, address=where, size=size), self.assertRaises(ValueError):
                MODULE.audit_flash_section(".flash.user", kind, flags, where, size)

    def test_sd_boot_move_requires_one_exact_named_extent_and_no_hidden_code(self):
        base = [("psram.probe", 0x40000120, 0x40000920),
                ("psram_memory.prepare__func_43", 0x40000920, 0x40001120)]
        moved = ("sdmmc_probe.run", 0x40001120, 0x40003920)
        def check(functions, span=(0x40001120, 0x40003920)):
            return MODULE.audit_boot_functions(functions, 0x40000120, 0x40003920,
                                                0x4ff20000, 0x4ff48000, sdmmc_span=span)
        self.assertEqual(check(base + [moved])["sdmmc"]["start"], "0x40001120")
        for values, span in [(base + [moved], None), (base, (0x40001120, 0x40003920)),
                             (base + [moved], (0x40001122, 0x40003920)),
                             (base + [moved, ("hidden_irq", 0x40001130, 0x40001140)], (0x40001120, 0x40003920)),
                             (base + [moved, moved], (0x40001120, 0x40003920)),
                             (base + [("sdmmc_probe.run", 0x40001140, 0x40003920)], (0x40001140, 0x40003920))]:
            with self.subTest(functions=values, span=span), self.assertRaises(ValueError):
                check(values, span)

    def test_sd_runtime_callbacks_and_dma_buffers_remain_internal_and_aligned(self):
        low, high = 0x4ff00000, 0x4ff28000
        symbols = {"nih_storage_read":low + 128, "nih_storage_controller_begin":low + 256,
                   "nih_storage_controller_end":low + 384,
                   "sdmmc_probe.dma_data":low + 512, "sdmmc_probe.dma_descriptor":low + 1024}
        sizes = {"sdmmc_probe.dma_data":512,"sdmmc_probe.dma_descriptor":64}
        MODULE.audit_sdmmc_resident(symbols, sizes, low, high)
        for name in symbols:
            for address in (0x40001120,0x48004000,high):
                with self.subTest(name=name,address=address),self.assertRaises(ValueError):
                    MODULE.audit_sdmmc_resident({**symbols,name:address},sizes,low,high)
        for name in sizes:
            for address in (low + 1, high - 64):
                if address == high - 64 and sizes[name] == 64:continue
                with self.subTest(name=name,address=address),self.assertRaises(ValueError):
                    MODULE.audit_sdmmc_resident({**symbols,name:address},sizes,low,high)
            with self.subTest(name=name),self.assertRaises(ValueError):
                MODULE.audit_sdmmc_resident(symbols,{**sizes,name:sizes[name]+4},low,high)
            changed=symbols.copy();del changed[name]
            with self.assertRaises(ValueError):MODULE.audit_sdmmc_resident(changed,sizes,low,high)

    def test_descriptor_must_select_the_audited_mmu_page_size(self):
        data = bytearray(256)
        struct.pack_into("<I", data, 0, 0xABCD5432)
        data[180] = 16
        MODULE.audit_app_descriptor(data)
        for changed in (data[:255], b"bad!" + data[4:], data[:180] + b"\x0f" + data[181:]):
            with self.assertRaises(ValueError):
                MODULE.audit_app_descriptor(changed)

    def test_clock_boot_role_is_narrow_and_contiguous(self):
        functions = [("cpu_boot.run__func_1",0x40000120,0x40000320),
                     ("psram.probe",0x40000320,0x40000920),
                     ("psram_memory.prepare__func_43",0x40000920,0x40001120)]
        def check(values): return MODULE.audit_boot_functions(values,0x40000120,0x40001120,0x4ff00000,0x4ff28000)
        self.assertEqual(set(check(functions)),{"clock","probe","mapping"})
        for name in ("cpu_boot.unexpected__func_1","cpu_boot.run_forever"):
            with self.subTest(name=name),self.assertRaises(ValueError):check([(name,*functions[0][1:]),*functions[1:]])
        with self.assertRaises(ValueError):check([functions[0],("psram.probe",0x40000340,0x40000920),functions[2]])

    def test_flash_tables_are_bounded_read_only_progbits(self):
        MODULE.audit_flash_section(".flash.appdesc", 1, 2, 0x40000020, 256)
        for size in (1, 1986, 65504):
            for flags in (2, 18, 50):
                MODULE.audit_flash_section(".flash.rodata", 1, flags, 0x40010020, size)
        for flags in (3, 6, 19, 22, 51, 54, 130):
            with self.subTest(flags=flags), self.assertRaises(ValueError):
                MODULE.audit_flash_section(".flash.rodata", 1, flags, 0x40010020, 64)
        for kind, flags, address, size in ((8, 2, 0x40010020, 64), (1, 3, 0x40010020, 64),
                                            (1, 6, 0x40010020, 64), (1, 2, 0x40010024, 64),
                                            (1, 2, 0x40010020, 0), (1, 2, 0x40010020, 65505)):
            with self.subTest(kind=kind, flags=flags, size=size), self.assertRaises(ValueError):
                MODULE.audit_flash_section(".flash.rodata", kind, flags, address, size)
        with self.assertRaises(ValueError):
            MODULE.audit_flash_section(".flash.text", 1, 2, 0x40010020, 64)

    def test_flash_checksum_uses_known_fnv1a_vectors(self):
        for data, checksum in ((b"", 0x811c9dc5), (b"a", 0xe40c292c), (b"foobar", 0xbf9cf968)):
            with self.subTest(data=data):
                self.assertEqual(MODULE.fnv1a(data), checksum)

    def test_heap_is_the_unloaded_tail_after_primary_bss(self):
        for low, high, _ in MODULE.SRAM_PROFILES.values():
            start = high - 65536
            symbols = {"__bss_end": start - 16, "__heap_start": start, "__heap_end": high}
            sections = [{"name": ".bss", "address": hex(start - 32768 - 16), "bytes": 32768},
                        {"name": ".heap", "address": hex(start), "bytes": 65536}]
            self.assertEqual(MODULE.audit_heap_layout(symbols, sections, low, high)["bytes"], 65536)
            for field, value in (("__heap_start", start - 4096), ("__heap_start", start + 1),
                                 ("__heap_end", 0x48020000), ("__heap_start", high - 4096)):
                with self.subTest(field=field, value=hex(value)), self.assertRaises(ValueError):
                    MODULE.audit_heap_layout({**symbols, field: value}, sections, low, high)
            with self.assertRaisesRegex(ValueError, "overlaps"):
                MODULE.audit_heap_layout(symbols, sections + [{"name": ".bad", "address": hex(start), "bytes": 64}], low, high)
            with self.assertRaisesRegex(ValueError, "differs"):
                MODULE.audit_heap_layout(symbols, sections[:1], low, high)

    def test_loader_allocations_are_audited_including_unloaded_bss(self):
        report = {"memory": {"origin": "0x4ff00000", "end": "0x4ff28000"}}
        elf = loader_elf([(1, 2, 0x4ff2abd0, 8192), (8, 2, 0x4ff33bd0, 256), (1, 0, 0x4ff10000, 64)])
        result = MODULE.audit_loader(report, elf)
        self.assertEqual(result["gap_bytes"], 0x2bd0)
        self.assertEqual(len(result["allocated"]), 2)

    def test_loader_overlap_at_either_edge_or_nobits_is_rejected(self):
        report = {"memory": {"origin": "0x4ff20000", "end": "0x4ff48000"}}
        for kind in (1, 8):
            for address in (0x4ff1fffc, 0x4ff47ffc, 0x4ff30000):
                with self.subTest(kind=kind, address=address), self.assertRaisesRegex(ValueError, "overlaps"):
                    MODULE.audit_loader(report, loader_elf([(kind, 2, address, 64)]))

    def test_loader_requires_expected_elf_and_a_higher_live_allocation(self):
        report = {"memory": {"origin": "0x4ff00000", "end": "0x4ff28000"}}
        with self.assertRaisesRegex(ValueError, "ELF32"):
            MODULE.audit_loader(report, b"invalid")
        with self.assertRaisesRegex(ValueError, "missing live"):
            MODULE.audit_loader(report, loader_elf([(1, 0, 0x4ff30000, 64)]))

    def test_loader_cache_and_revision_must_match_the_native_contract(self):
        common = "#define CONFIG_CACHE_L2_CACHE_SIZE 0x20000\n#define CONFIG_CACHE_L2_CACHE_LINE_SIZE 64\n"
        device = common + "#define CONFIG_ESP32P4_SELECTS_REV_LESS_V3 1\n"
        self.assertEqual(MODULE.audit_loader_config(common, "emulator")["l2_bytes"], 0x20000)
        self.assertEqual(MODULE.audit_loader_config(device, "device")["line_bytes"], 64)
        for config, profile in ((common.replace("0x20000", "0x40000"), "emulator"),
                                (common.replace("SIZE 64", "SIZE 128"), "emulator"),
                                (device, "emulator"), (common, "device")):
            with self.subTest(profile=profile), self.assertRaises(ValueError):
                MODULE.audit_loader_config(config, profile)

    def test_fp_load_store_arithmetic_and_fma(self):
        for instruction in (0x00052507, 0x00a52027, 0x00b57553, 0x00000043):
            with self.subTest(instruction=hex(instruction)):
                self.assertTrue(MODULE.is_fp_instruction(instruction, 4))

    def test_only_fp_status_csrs_are_classified(self):
        self.assertTrue(MODULE.is_fp_instruction(0x00302573, 4))  # frcsr
        self.assertTrue(MODULE.is_fp_instruction(0x00101073, 4))  # fsflags
        self.assertFalse(MODULE.is_fp_instruction(0x30002573, 4))  # mstatus
        self.assertFalse(MODULE.is_fp_instruction(0x10500073, 4))  # wfi

    def test_rv32_compressed_fp_is_not_integer_stack_access(self):
        for instruction in (0x6000, 0x6002, 0xe000, 0xe002):
            self.assertTrue(MODULE.is_fp_instruction(instruction, 2))
        for instruction in (0x4000, 0x4002, 0xc000, 0xc002, 0x0001):
            self.assertFalse(MODULE.is_fp_instruction(instruction, 2))


class SQLiteBoundaryTests(unittest.TestCase):
    def test_flash_sql_requires_opt_in_and_no_writable_or_outside_sections(self):
        MODULE.audit_flash_section(".flash.sqltext", 1, 6, 0x40020000, 64, True)
        MODULE.audit_flash_section(".flash.sqlrodata", 1, 50, 0x40020100, 64, True)
        for name, flags, address, enabled in ((".flash.sqltext", 6, 0x40020000, False),
                (".flash.sqltext", 7, 0x40020000, True), (".flash.sqlrodata", 3, 0x40020100, True),
                (".flash.sqltext", 6, 0x400c0000, True)):
            with self.subTest(name=name, flags=flags), self.assertRaises(ValueError):
                MODULE.audit_flash_section(name, 1, flags, address, 64, enabled)

    def test_sql_manifest_cannot_silently_admit_a_resident_function(self):
        funcs = [("psram.probe", 0x40000120, 0x40000140),
                 ("psram_memory.prepare__func_1", 0x40000140, 0x40000160),
                 ("heap.allocTask", 0x40020000, 0x40020020)]
        with self.assertRaisesRegex(ValueError, "non-manifest"):
            MODULE.audit_boot_functions(funcs, 0x40000120, 0x40000160, 0x4ff20000, 0x4ff48000,
                                        (0x40020000, 0x40020100), ["sqlite3_open"])
        funcs[-1] = ("sqlite3_open", 0x40020000, 0x40020020)
        result = MODULE.audit_boot_functions(funcs, 0x40000120, 0x40000160, 0x4ff20000, 0x4ff48000,
                                            (0x40020000, 0x40020100), ["sqlite3_open"])
        self.assertEqual(set(result), {"probe", "mapping"})

    def test_c_static_stack_metadata_has_bounded_checked_records(self):
        funcs = [("sqlite3_open", 0x40020000, 0x40020020)]
        result = MODULE.decode_stack_sizes(struct.pack("<I", 0x40020000) + bytes([0x80, 0x06]), funcs)
        self.assertEqual(result["maximum_reported_frame_bytes"], 768)
        for data in (b"x", struct.pack("<I", 0x40020000) + b"\x80", struct.pack("<I", 0x40020020) + b"\0"):
            with self.subTest(data=data), self.assertRaises(ValueError):
                MODULE.decode_stack_sizes(data, funcs)


def loader_elf(sections):
    elf = bytearray(52 + 40 * len(sections))
    elf[:7] = b"\x7fELF\x01\x01\x01"
    struct.pack_into("<HHIIIIIHHHHHH", elf, 16, 2, 243, 1, 0, 0, 52, 0, 52, 0, 0, 40, len(sections), 0)
    for index, (kind, flags, address, size) in enumerate(sections):
        struct.pack_into("<10I", elf, 52 + index * 40, 0, kind, flags, address, 0, size, 0, 0, 4, 0)
    return bytes(elf)


if __name__ == "__main__":
    unittest.main()
