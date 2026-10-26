"""Regression checks for accepting complete native execution evidence."""
import importlib.util
from pathlib import Path
import re
import unittest

SPEC = importlib.util.spec_from_file_location("native_log", Path(__file__).with_name("check-native-log.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def complete_log(mode="integer", psram_size="0"):
    lines = ["NIHOS_NATIVE_BOOT backend=zig-sram rtos=none",
             "NIHOS_NATIVE_MODE floating=" + ("0" if mode == "integer" else "1"),
             "NIHOS_NATIVE_COMPILER enabled=" + ("1" if mode == "compiled" else "0"),
             "NIHOS_NATIVE_CRT_PASS bss=zero data=valid ecall=returned"]
    sizes = {"0": (0, 0), "4M": (4 << 20, 1), "8M": (8 << 20, 3),
             "16M": (16 << 20, 5), "32M": (32 << 20, 7), "64M": (64 << 20, 6)}
    size, density = sizes[psram_size]
    lines.append("NIHOS_NATIVE_BOOT_CODE start=40000120 end=40001120 probe=40000140 mapping={:08x} completed=00000001".format(
        0x40000940 if size else 0))
    lines.append("NIHOS_NATIVE_PSRAM status={:08x} configuration={:08x} identity={:08x} "
                 "bytes={:08x} transactions=00000004 mapped={:08x} allocatable=00000000".format(
                     int(size != 0), 0x0d00 if size else 0, 0xc8 | density if size else 0, size, size))
    lines.append("NIHOS_NATIVE_PSRAM_SUPPLY programmed=00000001 calibrated=00000000 "
                 "dref=00000006 mul=00000005 control=00000180 analog=66800000 settled=00000001")
    addresses = size.bit_length() - 1 if size else 0
    values = [1, 0x28, 0x40, 0x0b, addresses, 2, addresses * 2, addresses * 2, 13 + addresses * 4] if size else [0] * 8 + [4]
    names = ("status", "mr0", "mr4", "mr8", "addresses", "passes", "reads", "writes", "transactions")
    lines.append("NIHOS_NATIVE_PSRAM_IO" + "".join(" {}={:08x}".format(name, value) for name, value in zip(names, values)))
    values = [1, 0, 64, 0, 0, 0, size, 1024, 36, 36, 72, 5] if size else [0] * 12
    names = ("status", "failure", "line_bytes", "last_address", "last_actual", "last_expected", "bytes", "entries", "cpu_checks", "command_checks", "transactions", "syncs")
    lines.append("NIHOS_NATIVE_PSRAM_MAP" + "".join(" {}={:08x}".format(name, value) for name, value in zip(names, values)))
    values = [1, 64, 3072, 3072, 48, 1] if size else [0] * 6
    names = ("status", "rounds", "owner_checks", "peer_checks", "command_checks", "syncs")
    lines.append("NIHOS_NATIVE_PSRAM_SMP" + "".join(" {}={:08x}".format(name, value) for name, value in zip(names, values)))
    for count in [1] + list(range(10, 301, 10)):
        lines.append("NIHOS_NATIVE_HEARTBEAT round={0:08x} cpu0={1:08x} cpu1={1:08x} "
                     "ticks0={2:08x} ticks1={2:08x}".format(count, count * 100, count * 4))
        if count % 100 == 0:
            for hart in range(2):
                lines.append("NIHOS_NATIVE_TASKS hart={0:08x} work0={1:08x} work1={1:08x} "
                             "cap0={2:08x} cap1={2:08x} switches={3:08x} calls=0000000c "
                             "reaped=00000003 sleeps=00000002 elapsed={3:08x}".format(
                                 hart, count * 1000, count * 2, count * 6))
            lines.append("NIHOS_NATIVE_SMP_PASS rounds=100 timers=both rtos=none")
    lines.append("NIHOS_NATIVE_SOAK_PASS rounds=300 timers=both rtos=none")
    for hart in range(2):
        lines.append("NIHOS_NATIVE_IPI hart={0:08x} sent=00000040 received=00000040 "
                     "ipis=00000041 delivered=00000040 woken=00000040 rejected=00000000 "
                     "from_idle=00000040 entries=00000041 returns=00000041 "
                     "pending_before_wfi=00000001 self_ipi=00000001 "
                     "timer_start=00000708 timer_end=00000708 queued=00000000".format(hart))
    lines.append("NIHOS_NATIVE_IPI_IDLE_PASS exchanges=64 timer_fallback=none")
    for hart in range(2):
        values = ([1000, 1000, 100, 600, 79, 1, 680, 680, 5, 600 if mode == "compiled" else 0, 1] if mode != "integer" else [0] * 10 + [1])
        names = ("checks0", "checks1", "checks2", "timer", "calls", "ipi", "saves", "restores", "initial", "app_timer", "confirmed")
        lines.append("NIHOS_NATIVE_FP hart={:08x}".format(hart) + "".join(
            " {}={:08x}".format(name, value) for name, value in zip(names, values)))
        start = 0x4ff40000 + hart * 0x4000
        lines.append("NIHOS_NATIVE_MEMORY hart={:08x} start={:08x} end={:08x} "
                     "capacity=00003f80 used=000001c0 free=00003dc0 "
                     "checks0=00000004 checks1=00000004 rejected=00000003 confirmed=00000001".format(
                         hart, start, start + 0x4000))
        stride = (size - 3 * 65536) // 2 if size else 0
        start = 0x48030000 + hart * stride
        values = [start, start + stride, stride - 128, stride - 128, 0, 4, 4, 3, 1] if size else [0] * 9
        names = ("start", "end", "capacity", "used", "free", "checks0", "checks1", "rejected", "confirmed")
        lines.append("NIHOS_NATIVE_EXTERNAL hart={:08x}".format(hart) + "".join(
            " {}={:08x}".format(name, value) for name, value in zip(names, values)))
        heap_start = start + 128
        heap_end = start + stride - 64 - 2 * 65728
        units = (heap_end - heap_start - 128) // 64 if size else 0
        levels = (units - 1).bit_length() if size else 0
        metadata = max(64, 2 * (1 << levels))
        capacity = heap_end - heap_start - metadata - 128
        values = [heap_start, heap_end, metadata, capacity, capacity, 0, 100, 100, 13, 4, 4, levels, 3 * levels + 2, 1] if size else [0] * 14
        names = ("start", "end", "metadata", "capacity", "free", "live", "allocations", "frees", "rejected", "checks0", "checks1", "levels", "max_steps", "confirmed")
        lines.append("NIHOS_NATIVE_HEAP hart={:08x}".format(hart) + "".join(
            " {}={:08x}".format(name, value) for name, value in zip(names, values)))
        names = ("opened", "closed", "completed", "reclaimed", "reuses", "owned", "pending", "stale", "full", "forced", "pool_objects", "pool_rejected", "slab_objects", "slab_frees", "slab_rejected", "object_moves", "object_inplace", "object_rejected", "object_copy_bytes", "c_probes")
        values = [7, 6, 6, 10 if size else 0, 3, 0, 0, 3, 3 if size else 0, 1, 18 if size else 0, 6 if size else 0,
                  120 if size else 0, 24 if size else 0, 27 if size else 0,
                  8 if size else 0, 4 if size else 0, 8 if size else 0, 4208 if size else 0, 2 if size else 0]
        lines.append("NIHOS_NATIVE_RESOURCES hart={:08x}".format(hart) + "".join(
            " {}={:08x}".format(name, value) for name, value in zip(names, values)))
        lines.append("NIHOS_NATIVE_FLASH hart={:08x} start=40010020 end=40010820 bytes=00000800 "
                     "initial=12345678 final=12345678 checks=00001000 confirmed=00000001".format(hart))
        base = 0x4ff60000
        values = [base, base + 57344, base + hart * 8192, base + (hart + 1) * 8192,
                  base + 16384 + hart * 8192, base + 16384 + (hart + 1) * 8192,
                  base + 32768 + hart * 12288, base + 32768 + (hart + 1) * 12288,
                  base + (hart + 1) * 8192 - 256, base + 16384 + (hart + 1) * 8192 - 256,
                  base + 32768 + hart * 12288 + 4096 - 256, base + 32768 + hart * 12288 + 8192 - 256,
                  base + 32768 + hart * 12288 + 12288 - 256, 1000, 20480, 1]
        names = ("start", "end", "boot_start", "boot_end", "irq_start", "irq_end", "task_start", "task_end",
                 "boot_frame", "irq_sp", "task0_frame", "task1_frame", "task2_frame", "frames", "zeroed", "confirmed")
        lines.append("NIHOS_NATIVE_STACKS hart={:08x}".format(hart) + "".join(
            " {}={:08x}".format(name, value) for name, value in zip(names, values)))
    lines.append("NIHOS_NATIVE_FP_PASS floating=" + ("0" if mode == "integer" else "1"))
    return "\n".join(lines)


def complete_image():
    return {"elf_sha256": "tested-elf",
            "heap": {"start": "0x4ff40000", "end": "0x4ff48000", "bytes": 32768},
            "stacks": {"start": "0x4ff60000", "end": "0x4ff6e000"},
            "flash_records": {"start": "0x40010020", "end": "0x40010820", "bytes": 2048, "fnv1a": 0x12345678},
            "flash_boot": {"start": "0x40000120", "end": "0x40001120", "functions": {
                "probe": {"start": "0x40000120", "end": "0x40000920"},
                "mapping": {"start": "0x40000920", "end": "0x40001120"}}}}


class NativeLogTests(unittest.TestCase):
    def test_stack_owners_cannot_be_missing_or_duplicated(self):
        log = complete_log()
        line = next(line for line in log.splitlines() if line.startswith("NIHOS_NATIVE_STACKS"))
        for changed in (log.replace(line, ""), log + "\n" + line):
            with self.assertRaisesRegex(ValueError, "stack"):
                MODULE.check(changed)

    def test_stack_dimensions_initialization_and_owned_samples_are_required(self):
        log = complete_log()
        line = next(line for line in log.splitlines() if line.startswith("NIHOS_NATIVE_STACKS"))
        for old, new in (("end=4ff6e000", "end=4ff6d000"), ("boot_end=4ff62000", "boot_end=4ff61000"),
                         ("irq_start=4ff64000", "irq_start=4ff66000"), ("task_end=4ff6b000", "task_end=4ff6a000"),
                         ("boot_frame=4ff61f00", "boot_frame=4ff60000"), ("irq_sp=4ff65f00", "irq_sp=4ff66000"),
                         ("task0_frame=4ff68f00", "task0_frame=4ff69f00"), ("task1_frame=4ff69f00", "task1_frame=00000000"),
                         ("task2_frame=4ff6af00", "task2_frame=4ff6af01"), ("frames=000003e8", "frames=00000000"),
                         ("zeroed=00005000", "zeroed=00002000"), ("confirmed=00000001", "confirmed=00000000")):
            with self.subTest(value=new), self.assertRaisesRegex(ValueError, "stack"):
                MODULE.check(log.replace(line, line.replace(old, new)))

    def test_both_sram_domains_are_bound_to_the_audited_image(self):
        log = complete_log()
        image = complete_image()
        MODULE.check(log, image=image)
        for changed in ({**image, "heap": {**image["heap"], "start": "0x4ff40040"}},
                        {**image, "stacks": {**image["stacks"], "start": "0x4ff60010"}}):
            with self.assertRaisesRegex(ValueError, "audited"):
                MODULE.check(log, image=changed)

    def test_slab_reuse_and_rejection_evidence_is_required(self):
        for size, expected in (("0", (0, 0, 0)), ("32M", (120, 24, 27))):
            log = complete_log(psram_size=size)
            for field, old in zip(("slab_objects", "slab_frees", "slab_rejected"), expected):
                token = " {}={:08x}".format(field, old)
                for value in ("", " {}={:08x}".format(field, old + 1)):
                    with self.subTest(size=size, field=field), self.assertRaisesRegex(ValueError, "resource"):
                        MODULE.check(log.replace(token, value), "integer", 0 if size == "0" else 32 << 20)

    def test_object_resize_copy_and_rejection_evidence_is_required(self):
        for size, expected in (("0", (0, 0, 0, 0, 0)), ("32M", (8, 4, 8, 4208, 2))):
            log = complete_log(psram_size=size)
            for field, old in zip(("object_moves", "object_inplace", "object_rejected", "object_copy_bytes", "c_probes"), expected):
                token = " {}={:08x}".format(field, old)
                for value in ("", " {}={:08x}".format(field, old + 1)):
                    with self.subTest(size=size, field=field), self.assertRaisesRegex(ValueError, "resource"):
                        MODULE.check(log.replace(token, value), "integer", 0 if size == "0" else 32 << 20)

    def test_flash_boot_execution_cannot_be_missing_or_duplicated(self):
        log = complete_log()
        line = next(line for line in log.splitlines() if line.startswith("NIHOS_NATIVE_BOOT_CODE"))
        for changed in (log.replace(line, ""), log + "\n" + line):
            with self.assertRaisesRegex(ValueError, "Flash boot"):
                MODULE.check(changed)

    def test_flash_boot_execution_requires_valid_pcs_and_completion(self):
        for size in ("0", "32M"):
            log = complete_log(psram_size=size)
            for old, new in (("start=40000120", "start=4ff00120"), ("end=40001120", "end=40010120"),
                             ("probe=40000140", "probe=40000141"), ("probe=40000140", "probe=4ff00140"),
                             ("completed=00000001", "completed=00000000"),
                             ("mapping=40000940" if size != "0" else "mapping=00000000",
                              "mapping=00000000" if size != "0" else "mapping=40000940")):
                changed = log.replace(old, new)
                with self.subTest(size=size, value=new), self.assertRaisesRegex(ValueError, "Flash boot"):
                    MODULE.check(changed, "integer", 0 if size == "0" else 32 << 20)

    def test_flash_boot_pcs_must_match_their_audited_function_roles(self):
        log = complete_log(psram_size="32M")
        image = complete_image()
        MODULE.check(log, "integer", 32 << 20, image)
        for old, new in (("probe=40000140", "probe=40000960"), ("mapping=40000940", "mapping=40000160"),
                         ("end=40001120", "end=40001122")):
            with self.subTest(value=new), self.assertRaisesRegex(ValueError, "audited"):
                MODULE.check(log.replace(old, new), "integer", 32 << 20, image)

    def test_flash_owner_evidence_cannot_be_missing_or_duplicated(self):
        log = complete_log()
        line = next(line for line in log.splitlines() if line.startswith("NIHOS_NATIVE_FLASH"))
        for changed in (log.replace(line, ""), log + "\n" + line):
            with self.assertRaisesRegex(ValueError, "Flash"):
                MODULE.check(changed)

    def test_flash_ranges_checksums_and_completion_are_required(self):
        log = complete_log()
        for old, new in (("start=40010020", "start=48010020"), ("end=40010820", "end=40010824"),
                         ("bytes=00000800", "bytes=00010000"), ("final=12345678", "final=12345679"),
                         ("checks=00001000", "checks=00000800"), ("confirmed=00000001", "confirmed=00000000")):
            changed = "\n".join(line.replace(old, new) if line.startswith("NIHOS_NATIVE_FLASH") else line
                                for line in log.splitlines())
            with self.subTest(value=new), self.assertRaisesRegex(ValueError, "Flash"):
                MODULE.check(changed)

    def test_both_harts_must_read_the_same_flash_content(self):
        log = complete_log()
        line = next(line for line in log.splitlines() if line.startswith("NIHOS_NATIVE_FLASH"))
        with self.assertRaisesRegex(ValueError, "inconsistent"):
            MODULE.check(log.replace(line, line.replace("12345678", "87654321")))

    def test_flash_content_is_bound_to_the_audited_image(self):
        log = complete_log()
        image = complete_image()
        self.assertEqual(MODULE.check(log, image=image)["image_elf_sha256"], "tested-elf")
        for field, wrong in (("start", "0x40010024"), ("end", "0x40010824"), ("bytes", 2049), ("fnv1a", 0)):
            changed = {**image, "flash_records": {**image["flash_records"], field: wrong}}
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "audited image"):
                MODULE.check(log, image=changed)

    def test_missing_or_duplicate_resource_owner_is_rejected(self):
        for size in ("0", "32M"):
            log = complete_log(psram_size=size)
            line = next(line for line in log.splitlines() if line.startswith("NIHOS_NATIVE_RESOURCES"))
            for changed in (log.replace(line, ""), log + "\n" + line):
                with self.subTest(size=size), self.assertRaisesRegex(ValueError, "resource"):
                    MODULE.check(changed, "integer", 0 if size == "0" else 32 << 20)

    def test_partial_cleanup_or_reuse_evidence_is_rejected(self):
        log = complete_log(psram_size="32M")
        for field, old, new in (("opened", 7, 6), ("closed", 6, 5), ("completed", 6, 5), ("reclaimed", 10, 9),
                                ("reuses", 3, 2), ("owned", 0, 1), ("pending", 0, 1), ("stale", 3, 2), ("full", 3, 2), ("forced", 1, 0)):
            changed = "\n".join(line.replace("{}={:08x}".format(field, old), "{}={:08x}".format(field, new))
                                if line.startswith("NIHOS_NATIVE_RESOURCES") else line for line in log.splitlines())
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "deferred task resource"):
                MODULE.check(changed, "integer", 32 << 20)

    def test_absent_die_cannot_claim_physical_reclamation(self):
        log = "\n".join(line.replace("reclaimed=00000000", "reclaimed=00000008")
                        if line.startswith("NIHOS_NATIVE_RESOURCES") else line for line in complete_log().splitlines())
        with self.assertRaisesRegex(ValueError, "deferred task resource"):
            MODULE.check(log)

    def test_pool_object_and_rejection_evidence_is_required(self):
        for size, objects, rejected in (("0", 0, 0), ("32M", 18, 6)):
            log = complete_log(psram_size=size)
            for field, old in (("pool_objects", objects), ("pool_rejected", rejected)):
                for new in (None, old + 1):
                    token = " {}={:08x}".format(field, old)
                    changed = log.replace(token, "" if new is None else " {}={:08x}".format(field, new))
                    with self.subTest(size=size, field=field, new=new), self.assertRaisesRegex(ValueError, "resource"):
                        MODULE.check(changed, "integer", 0 if size == "0" else 32 << 20)

    def test_two_normal_reaps_cannot_substitute_for_forced_termination(self):
        with self.assertRaisesRegex(ValueError, "lifecycle"):
            MODULE.check(complete_log().replace("reaped=00000003", "reaped=00000002"))

    def test_missing_or_duplicate_reusable_heap_owner_is_rejected(self):
        for size in ("0", "32M"):
            log = complete_log(psram_size=size)
            line = next(line for line in log.splitlines() if line.startswith("NIHOS_NATIVE_HEAP"))
            for changed in (log.replace(line, ""), log + "\n" + line):
                with self.subTest(size=size), self.assertRaisesRegex(ValueError, "reusable heap"):
                    MODULE.check(changed, "integer", 0 if size == "0" else 32 << 20)

    def test_reusable_heap_requires_recovery_and_a_bounded_walk(self):
        log = complete_log(psram_size="32M")
        for old, new in (("live=00000000", "live=00000001"), ("frees=00000064", "frees=00000063"),
                         ("allocations=00000064", "allocations=00000001"), ("rejected=0000000d", "rejected=0000000c"),
                         ("max_steps=00000038", "max_steps=00000039"), ("checks0=00000004", "checks0=00000000"),
                         ("confirmed=00000001", "confirmed=00000000"), ("metadata=00080000", "metadata=00000000")):
            changed = "\n".join(line.replace(old, new) if line.startswith("NIHOS_NATIVE_HEAP") else line for line in log.splitlines())
            self.assertNotEqual(log, changed)
            with self.subTest(value=new), self.assertRaisesRegex(ValueError, "heap recovery/bounds"):
                MODULE.check(changed, "integer", 32 << 20)

    def test_reusable_heap_must_stay_inside_its_reserved_backing(self):
        log = complete_log(psram_size="32M")
        changed = "\n".join(line.replace("start=48030080", "start=48030000")
                            if line.startswith("NIHOS_NATIVE_HEAP") else line for line in log.splitlines())
        with self.assertRaisesRegex(ValueError, "heap recovery/bounds"):
            MODULE.check(changed, "integer", 32 << 20)

    def test_absent_die_cannot_publish_a_reusable_heap(self):
        log = "\n".join(line.replace("capacity=00000000", "capacity=00000001")
                        if line.startswith("NIHOS_NATIVE_HEAP") else line for line in complete_log().splitlines())
        with self.assertRaisesRegex(ValueError, "heap without mapped PSRAM"):
            MODULE.check(log)

    def test_missing_or_duplicate_external_owner_is_rejected(self):
        for size in ("0", "32M"):
            log = complete_log(psram_size=size)
            line = next(line for line in log.splitlines() if line.startswith("NIHOS_NATIVE_EXTERNAL"))
            for changed in (log.replace(line, ""), log + "\n" + line):
                with self.subTest(size=size), self.assertRaisesRegex(ValueError, "external memory"):
                    MODULE.check(changed, "integer", 0 if size == "0" else 32 << 20)

    def test_external_owners_must_exclude_reserved_pages_and_cover_the_tail(self):
        log = complete_log(psram_size="32M")
        for old, new in (("start=48030000", "start=48020000"),
                         ("end=49018000", "end=4a010000"),
                         ("start=49018000", "start=48030000"),
                         ("end=4a000000", "end=4c000000")):
            changed = "\n".join(line.replace(old, new) if line.startswith("NIHOS_NATIVE_EXTERNAL") else line
                                for line in log.splitlines())
            self.assertNotEqual(log, changed)
            with self.subTest(value=new), self.assertRaisesRegex(ValueError, "external ownership"):
                MODULE.check(changed, "integer", 32 << 20)

    def test_external_accounting_guards_and_worker_access_are_required(self):
        log = complete_log(psram_size="32M")
        for old, new in (("used=00fe7f80", "used=000001c0"), ("checks0=00000004", "checks0=00000000"),
                         ("checks1=00000004", "checks1=00000003"), ("rejected=00000003", "rejected=00000002"),
                         ("confirmed=00000001", "confirmed=00000000"), ("capacity=00fe7f80", "capacity=00fe8000")):
            changed = "\n".join(line.replace(old, new) if line.startswith("NIHOS_NATIVE_EXTERNAL") else line
                                for line in log.splitlines())
            self.assertNotEqual(log, changed)
            with self.subTest(value=new), self.assertRaisesRegex(ValueError, "external ownership"):
                MODULE.check(changed, "integer", 32 << 20)

    def test_absent_die_cannot_publish_external_capacity_or_allocation(self):
        log = complete_log()
        for field in ("start", "capacity", "used", "confirmed"):
            changed = "\n".join(line.replace(field + "=00000000", field + "=00000001")
                                if line.startswith("NIHOS_NATIVE_EXTERNAL") else line for line in log.splitlines())
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "without a mapped die"):
                MODULE.check(changed)

    def test_reserved_windows_alone_cannot_qualify_full_mapping(self):
        log = complete_log(psram_size="32M")
        changed = "\n".join(line.replace("bytes=02000000", "bytes=00030000")
                            if line.startswith("NIHOS_NATIVE_PSRAM_MAP") else line for line in log.splitlines())
        with self.assertRaisesRegex(ValueError, "mapping/cache"):
            MODULE.check(changed, "integer", 32 << 20)

    def test_missing_or_duplicate_mapping_or_psram_smp_is_rejected(self):
        log = complete_log(psram_size="32M")
        for marker in ("NIHOS_NATIVE_PSRAM_MAP", "NIHOS_NATIVE_PSRAM_SMP"):
            line = next(line for line in log.splitlines() if line.startswith(marker))
            for changed in (log.replace(line, ""), log + "\n" + line):
                with self.subTest(marker=marker), self.assertRaisesRegex(ValueError, "PSRAM .* evidence"):
                    MODULE.check(changed, "integer", 32 << 20)

    def test_partial_mmu_or_cache_bridge_cannot_qualify_mapping(self):
        log = complete_log(psram_size="32M")
        for old, new in (("status=00000001", "status=00000002"), ("failure=00000000", "failure=00000003"),
                         ("line_bytes=00000040", "line_bytes=00000080"), ("entries=00000400", "entries=00000003"),
                         ("cpu_checks=00000024", "cpu_checks=00000023"), ("command_checks=00000024", "command_checks=00000000"),
                         ("transactions=00000048", "transactions=00000047"), ("syncs=00000005", "syncs=00000004")):
            changed = "\n".join(line.replace(old, new) if line.startswith("NIHOS_NATIVE_PSRAM_MAP") else line for line in log.splitlines())
            with self.subTest(value=new), self.assertRaisesRegex(ValueError, "mapping/cache"):
                MODULE.check(changed, "integer", 32 << 20)

    def test_partial_cross_core_handoff_is_rejected(self):
        log = complete_log(psram_size="32M")
        for old, new in (("rounds=00000040", "rounds=0000003f"), ("owner_checks=00000c00", "owner_checks=00000000"),
                         ("peer_checks=00000c00", "peer_checks=00000bff"), ("command_checks=00000030", "command_checks=00000000"),
                         ("syncs=00000001", "syncs=00000000")):
            changed = "\n".join(line.replace(old, new) if line.startswith("NIHOS_NATIVE_PSRAM_SMP") else line for line in log.splitlines())
            with self.subTest(value=new), self.assertRaisesRegex(ValueError, "cross-core handoff"):
                MODULE.check(changed, "integer", 32 << 20)

    def test_known_capacity_without_the_reserved_mapping_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "PSRAM discovery"):
            MODULE.check(complete_log(psram_size="32M").replace("mapped=02000000", "mapped=00000000"), "integer", 32 << 20)

    def test_absent_die_cannot_report_mapped_or_cross_core_access(self):
        for marker in ("NIHOS_NATIVE_PSRAM_MAP", "NIHOS_NATIVE_PSRAM_SMP"):
            log = "\n".join(line.replace("status=00000000", "status=00000001") if line.startswith(marker) else line
                            for line in complete_log().splitlines())
            with self.subTest(marker=marker), self.assertRaises(ValueError):
                MODULE.check(log)

    def test_missing_or_duplicate_supply_or_data_evidence_is_rejected(self):
        log = complete_log()
        for marker in ("NIHOS_NATIVE_PSRAM_SUPPLY", "NIHOS_NATIVE_PSRAM_IO"):
            line = next(line for line in log.splitlines() if line.startswith(marker))
            for changed in (log.replace(line, ""), log + "\n" + line):
                with self.subTest(marker=marker), self.assertRaisesRegex(ValueError, "PSRAM .* evidence"):
                    MODULE.check(changed)

    def test_failed_or_inconsistent_supply_programming_is_rejected(self):
        for old, new in (("programmed=00000001", "programmed=00000000"),
                         ("settled=00000001", "settled=00000000"),
                         ("control=00000180", "control=00004180"),
                         ("analog=66800000", "analog=00000000"),
                         ("dref=00000006", "dref=00000007")):
            with self.subTest(value=new), self.assertRaisesRegex(ValueError, "supply programming"):
                MODULE.check(complete_log().replace(old, new))

    def test_complete_calibration_fields_are_accepted(self):
        log = complete_log().replace("calibrated=00000000", "calibrated=00000001")
        log = log.replace("dref=00000006 mul=00000005", "dref=00000009 mul=00000003").replace("analog=66800000", "analog=95800000")
        self.assertEqual(MODULE.check(log)["psram_supply"]["calibrated"], 1)

    def test_detected_capacity_requires_complete_mode_and_data_checks(self):
        log = complete_log(psram_size="32M")
        for old, new in (("mr0=00000028", "mr0=00000024"), ("mr4=00000040", "mr4=00000000"),
                         ("mr8=0000000b", "mr8=0000004b"), ("addresses=00000019", "addresses=00000001"),
                         ("passes=00000002", "passes=00000001"), ("reads=00000032", "reads=00000031"),
                         ("writes=00000032", "writes=00000031"), ("transactions=00000071", "transactions=00000070")):
            with self.subTest(value=new), self.assertRaisesRegex(ValueError, "data/mode qualification"):
                MODULE.check(log.replace(old, new), "integer", 32 << 20)

    def test_absent_die_must_skip_mode_and_data_commands(self):
        with self.assertRaisesRegex(ValueError, "absent PSRAM received"):
            MODULE.check(complete_log().replace("writes=00000000", "writes=00000001"))

    def test_all_detected_psram_sizes_require_the_requested_capacity(self):
        for size, amount in (("4M", 4), ("8M", 8), ("16M", 16), ("32M", 32), ("64M", 64)):
            with self.subTest(size=size):
                report = MODULE.check(complete_log(psram_size=size), "integer", amount << 20)
                self.assertEqual(report["psram"]["bytes"], amount << 20)
                self.assertEqual(report["psram"]["mapped"], amount << 20)
                self.assertEqual(report["external_registered_bytes"], (amount << 20) - 3 * 65536 - 256)
                self.assertGreater(report["external_allocatable_bytes"], 0)

    def test_missing_or_duplicate_psram_discovery_is_rejected(self):
        log = complete_log()
        line = next(line for line in log.splitlines() if line.startswith("NIHOS_NATIVE_PSRAM"))
        for changed in (log.replace(line, ""), log + "\n" + line):
            with self.assertRaisesRegex(ValueError, "PSRAM discovery"):
                MODULE.check(changed)

    def test_discovery_timeout_wrong_size_and_premature_exposure_are_rejected(self):
        log = complete_log(psram_size="32M")
        with self.assertRaisesRegex(ValueError, "PSRAM discovery"):
            MODULE.check(log, "integer", 64 << 20)
        for old, new in (("status=00000001", "status=00000003"),
                         ("transactions=00000004", "transactions=00000002"),
                         ("mapped=02000000", "mapped=00030000"),
                         ("allocatable=00000000", "allocatable=02000000")):
            with self.subTest(field=old), self.assertRaisesRegex(ValueError, "PSRAM discovery"):
                MODULE.check(log.replace(old, new), "integer", 32 << 20)

    def test_psram_capacity_must_agree_with_vendor_good_die_and_density(self):
        for old, new in (("configuration=00000d00", "configuration=00001000"),
                         ("identity=000000cf", "identity=0000000f"),
                         ("identity=000000cf", "identity=000000cd")):
            with self.subTest(value=new), self.assertRaisesRegex(ValueError, "PSRAM identity"):
                MODULE.check(complete_log(psram_size="32M").replace(old, new), "integer", 32 << 20)

    def test_absent_die_cannot_carry_an_old_identity(self):
        with self.assertRaisesRegex(ValueError, "absent PSRAM"):
            MODULE.check(complete_log().replace("identity=00000000", "identity=000000cf"))

    def test_missing_or_duplicate_memory_owner_is_rejected(self):
        log = complete_log()
        with self.assertRaisesRegex(ValueError, "per-hart memory"):
            MODULE.check("\n".join(line for line in log.splitlines() if "NIHOS_NATIVE_MEMORY" not in line))
        with self.assertRaisesRegex(ValueError, "duplicate memory"):
            MODULE.check(log.replace("NIHOS_NATIVE_MEMORY hart=00000001", "NIHOS_NATIVE_MEMORY hart=00000000"))

    def test_incomplete_memory_guard_or_allocator_evidence_is_rejected(self):
        for field, old, new in (("used", "000001c0", "000001c1"), ("free", "00003dc0", "00003dc1"),
                                ("checks0", "00000004", "00000000"), ("rejected", "00000003", "00000002"),
                                ("confirmed", "00000001", "00000000")):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "memory ownership"):
                MODULE.check("\n".join(line.replace(field + "=" + old, field + "=" + new)
                                       if line.startswith("NIHOS_NATIVE_MEMORY") else line
                                       for line in complete_log().splitlines()))

    def test_external_or_unaligned_memory_cannot_qualify_sram(self):
        for address in ("48018000", "4ff40001", "4ff18000"):
            with self.subTest(address=address), self.assertRaisesRegex(ValueError, "memory ownership"):
                MODULE.check(complete_log().replace("start=4ff40000", "start=" + address))

    def test_overlapping_memory_owners_are_rejected(self):
        log = complete_log().replace("start=4ff44000 end=4ff48000", "start=4ff40000 end=4ff44000")
        with self.assertRaisesRegex(ValueError, "overlapping memory"):
            MODULE.check(log)

    def test_complete_continuous_run(self):
        report = MODULE.check(complete_log())
        self.assertEqual(report["rounds"], 300)
        self.assertEqual(report["cpu1_interrupts"], 1200)

    def test_reboot_cannot_count_as_continuous_execution(self):
        with self.assertRaisesRegex(ValueError, "reboot"):
            MODULE.check(complete_log() * 2)

    def test_one_success_checkpoint_is_not_a_full_run(self):
        log = complete_log().replace("NIHOS_NATIVE_SOAK_PASS", "INCOMPLETE")
        with self.assertRaisesRegex(ValueError, "continuous"):
            MODULE.check(log)

    def test_frozen_hart_and_timer_are_both_rejected(self):
        for field in ("cpu1", "ticks1"):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "stopped"):
                log = complete_log()
                log = re.sub(field + r"=[0-9a-f]{8}", field + "=00000001", log)
                MODULE.check(log)

    def test_failure_after_a_checkpoint_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "failure/trap"):
            MODULE.check(complete_log() + "\nNIHOS_NATIVE_FAIL timer progress")

    def test_early_end_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "incomplete heartbeat"):
            lines = complete_log().splitlines()
            first = next(index for index, line in enumerate(lines) if line.startswith("NIHOS_NATIVE_HEARTBEAT"))
            MODULE.check("\n".join(lines[:first + 1]))

    def test_timer_only_smoke_does_not_qualify_scheduler(self):
        log = "\n".join(line for line in complete_log().splitlines() if "NIHOS_NATIVE_TASKS" not in line)
        with self.assertRaisesRegex(ValueError, "per-hart task"):
            MODULE.check(log)

    def test_duplicate_hart_cannot_substitute_for_cpu1(self):
        log = complete_log().replace("hart=00000001", "hart=00000000")
        with self.assertRaises(ValueError):
            MODULE.check(log)

    def test_frozen_busy_task_or_preemption_is_rejected(self):
        for field in ("work0", "work1", "cap0", "cap1"):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "stopped"):
                MODULE.check(re.sub(field + r"=[0-9a-f]{8}", field + "=00000004", complete_log()))

    def test_incomplete_lifecycle_reap_or_sleep_is_rejected(self):
        for field, value in (("reaped", "00000003"), ("sleeps", "00000002")):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "lifecycle"):
                MODULE.check(complete_log().replace(field + "=" + value, field + "=00000001"))

    def test_scheduler_only_run_does_not_qualify_ipi(self):
        log = "\n".join(line for line in complete_log().splitlines() if "NIHOS_NATIVE_IPI" not in line)
        with self.assertRaisesRegex(ValueError, "IPI/idle evidence"):
            MODULE.check(log)

    def test_timer_fallback_does_not_qualify_idle_wake(self):
        with self.assertRaisesRegex(ValueError, "periodic timer"):
            MODULE.check(complete_log().replace("timer_end=00000708", "timer_end=00000709"))

    def test_missing_idle_wake_or_delivery_is_rejected(self):
        for field in ("sent", "received", "delivered", "woken", "from_idle", "returns"):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "IPI delivery/idle"):
                MODULE.check(complete_log().replace(field + "=00000040", field + "=00000001")
                             .replace(field + "=00000041", field + "=00000001"))

    def test_duplicate_ipi_owner_and_undrained_inbox_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate IPI"):
            MODULE.check(complete_log().replace("NIHOS_NATIVE_IPI hart=00000001", "NIHOS_NATIVE_IPI hart=00000000"))
        with self.assertRaisesRegex(ValueError, "IPI delivery/idle"):
            MODULE.check(complete_log().replace("queued=00000000", "queued=00000001"))

    def test_missing_pending_before_wfi_probe_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "IPI delivery/idle"):
            MODULE.check(complete_log().replace("pending_before_wfi=00000001", "pending_before_wfi=00000000"))

    def test_floating_run_requires_all_trap_sources_and_balanced_copies(self):
        report = MODULE.check(complete_log("floating"), "floating")
        self.assertEqual(report["floating"][0]["saves"], 680)
        for field in ("checks0", "checks1", "checks2", "ipi", "restores", "initial", "confirmed"):
            with self.subTest(field=field), self.assertRaises(ValueError):
                MODULE.check(re.sub(field + r"=[0-9a-f]{8}", field + "=00000000", complete_log("floating")))

    def test_integer_run_rejects_fp_copies_and_mode_mismatch(self):
        with self.assertRaisesRegex(ValueError, "overhead"):
            MODULE.check(complete_log("floating").replace("floating=1", "floating=0"))
        with self.assertRaisesRegex(ValueError, "requested build"):
            MODULE.check(complete_log(), "floating")

    def test_missing_final_fp_or_running_task_ipi_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "FP evidence"):
            MODULE.check(complete_log().replace("NIHOS_NATIVE_FP_PASS", "INCOMPLETE"))
        with self.assertRaisesRegex(ValueError, "IPI delivery/idle"):
            MODULE.check(complete_log().replace("self_ipi=00000001", "self_ipi=00000000"))

    def test_compiled_mode_requires_pc_captures_and_mode_identity(self):
        self.assertEqual(MODULE.check(complete_log("compiled"), "compiled")["mode"], "compiled")
        with self.assertRaisesRegex(ValueError, "compiler-generated task preemption"):
            MODULE.check(complete_log("compiled").replace("app_timer=00000258", "app_timer=00000000"))
        with self.assertRaisesRegex(ValueError, "requested build"):
            MODULE.check(complete_log("floating"), "compiled")

    def test_failed_compiled_calculation_cannot_pass_existing_markers(self):
        with self.assertRaisesRegex(ValueError, "failure/trap"):
            MODULE.check(complete_log("compiled") + "\nNIHOS_NATIVE_FAIL compiled FP invariant")


if __name__ == "__main__":
    unittest.main()
