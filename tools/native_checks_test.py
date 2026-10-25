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
    lines.append("NIHOS_NATIVE_PSRAM status={:08x} configuration={:08x} identity={:08x} "
                 "bytes={:08x} transactions=00000004 mapped=00000000 allocatable=00000000".format(
                     int(size != 0), 0x0d00 if size else 0, 0xc8 | density if size else 0, size))
    lines.append("NIHOS_NATIVE_PSRAM_SUPPLY programmed=00000001 calibrated=00000000 "
                 "dref=00000006 mul=00000005 control=00000180 analog=66800000 settled=00000001")
    addresses = size.bit_length() - 1 if size else 0
    values = [1, 0x28, 0x40, 0x0b, addresses, 2, addresses * 2, addresses * 2, 13 + addresses * 4] if size else [0] * 8 + [4]
    names = ("status", "mr0", "mr4", "mr8", "addresses", "passes", "reads", "writes", "transactions")
    lines.append("NIHOS_NATIVE_PSRAM_IO" + "".join(" {}={:08x}".format(name, value) for name, value in zip(names, values)))
    for count in [1] + list(range(10, 301, 10)):
        lines.append("NIHOS_NATIVE_HEARTBEAT round={0:08x} cpu0={1:08x} cpu1={1:08x} "
                     "ticks0={2:08x} ticks1={2:08x}".format(count, count * 100, count * 4))
        if count % 100 == 0:
            for hart in range(2):
                lines.append("NIHOS_NATIVE_TASKS hart={0:08x} work0={1:08x} work1={1:08x} "
                             "cap0={2:08x} cap1={2:08x} switches={3:08x} calls=0000000c "
                             "reaped=00000002 sleeps=00000002 elapsed={3:08x}".format(
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
        start = 0x4ff18000 + hart * 0x4000
        lines.append("NIHOS_NATIVE_MEMORY hart={:08x} start={:08x} end={:08x} "
                     "capacity=00003f80 used=000001c0 free=00003dc0 "
                     "checks0=00000004 checks1=00000004 rejected=00000003 confirmed=00000001".format(
                         hart, start, start + 0x4000))
    lines.append("NIHOS_NATIVE_FP_PASS floating=" + ("0" if mode == "integer" else "1"))
    return "\n".join(lines)


class NativeLogTests(unittest.TestCase):
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
                self.assertEqual(report["psram"]["mapped"], 0)

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
                         ("mapped=00000000", "mapped=02000000"),
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
        for address in ("48018000", "4ff18001"):
            with self.subTest(address=address), self.assertRaisesRegex(ValueError, "memory ownership"):
                MODULE.check(complete_log().replace("start=4ff18000", "start=" + address))

    def test_overlapping_memory_owners_are_rejected(self):
        log = complete_log().replace("start=4ff1c000 end=4ff20000", "start=4ff18000 end=4ff1c000")
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
            MODULE.check("\n".join(complete_log().splitlines()[:8]))

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
        for field in ("reaped", "sleeps"):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "lifecycle"):
                MODULE.check(complete_log().replace(field + "=00000002", field + "=00000001"))

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
