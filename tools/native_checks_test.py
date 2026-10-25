"""Regression checks for accepting complete native execution evidence."""
import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("native_log", Path(__file__).with_name("check-native-log.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def complete_log():
    lines = ["NIHOS_NATIVE_BOOT backend=zig-sram rtos=none",
             "NIHOS_NATIVE_CRT_PASS bss=zero data=valid ecall=returned"]
    for count in [1] + list(range(10, 301, 10)):
        lines.append("NIHOS_NATIVE_HEARTBEAT round={0:08x} cpu0={1:08x} cpu1={1:08x} "
                     "ticks0={2:08x} ticks1={2:08x}".format(count, count * 100, count * 4))
        if count % 100 == 0:
            lines.append("NIHOS_NATIVE_SMP_PASS rounds=100 timers=both rtos=none")
    lines.append("NIHOS_NATIVE_SOAK_PASS rounds=300 timers=both rtos=none")
    return "\n".join(lines)


class NativeLogTests(unittest.TestCase):
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
                import re
                log = re.sub(field + r"=[0-9a-f]{8}", field + "=00000001", log)
                MODULE.check(log)

    def test_failure_after_a_checkpoint_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "failure/trap"):
            MODULE.check(complete_log() + "\nNIHOS_NATIVE_FAIL timer progress")

    def test_early_end_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "incomplete heartbeat"):
            MODULE.check("\n".join(complete_log().splitlines()[:8]))


if __name__ == "__main__":
    unittest.main()
