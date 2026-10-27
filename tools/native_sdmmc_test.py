import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("oracle", Path(__file__).with_name("check-sdmmc-oracle.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def log_and_report():
    lines = ["NIHOS_SDMMC_IDF_ORACLE_BEGIN read_only=1 width=1 khz=400",
             "NIHOS_SDMMC_IDF_ORACLE_CARD sectors=2048"]
    for iteration in range(2):
        for lba, crc in zip((0, 1, 1024, 2047), (1, 2, 3, 4)):
            lines.append(f"NIHOS_SDMMC_IDF_ORACLE_READ pass={iteration} lba={lba:08x} crc={crc:08x} tail=ffff")
    lines.append("NIHOS_SDMMC_IDF_ORACLE_PASS reads=8 writes=0")
    report = {"evidence": "physical-device", "image_elf_sha256": "test-elf", "sdmmc": {
        "sectors_low": 2048, "sectors_high": 0, "reads": 8,
        "crc0": 1, "crc1": 2, "crc_middle": 3, "crc_last": 4}}
    return "\n".join(lines), report


class OracleTests(unittest.TestCase):
    def test_all_four_sectors_must_match_the_independent_reader(self):
        log, report = log_and_report()
        self.assertTrue(MODULE.compare(log, report)["passed"])
        report["sdmmc"]["crc0"] = 0
        with self.assertRaisesRegex(ValueError, "CRCs differ"):
            MODULE.compare(log, report)

    def test_partial_unstable_and_reordered_oracle_reads_fail(self):
        log, report = log_and_report()
        for changed in (log.replace("PASS reads=8 writes=0", "STOP"),
                        log.replace("pass=1 lba=00000000 crc=00000001", "pass=1 lba=00000000 crc=00000005"),
                        log.replace("pass=1 lba=00000001", "pass=1 lba=00000002")):
            with self.assertRaises(ValueError):
                MODULE.compare(changed, report)

    def test_emulator_and_different_card_capacity_cannot_pass(self):
        log, report = log_and_report()
        with self.assertRaises(ValueError):
            MODULE.compare(log, {**report, "evidence": "emulator"})
        report["sdmmc"]["sectors_low"] = 4096
        with self.assertRaisesRegex(ValueError, "capacities differ"):
            MODULE.compare(log, report)

    def test_wide_oracle_must_report_its_working_configuration(self):
        log, report = log_and_report()
        log = log.replace("width=1 khz=400", "width=4 khz=20000")
        with self.assertRaisesRegex(ValueError, "working bus"):
            MODULE.compare(log, report)
        log += "\nNIHOS_SDMMC_IDF_ORACLE_CONFIG width=4 khz=20000"
        self.assertEqual(MODULE.compare(log, report)["oracle_bus_bits"], 4)

    def test_distributed_native_and_oracle_reads_must_match(self):
        log, report = log_and_report()
        report["sdmmc_sweeps"] = [{"index": i, "samples": 1024, "digest": 0x12345678} for i in range(3)]
        with self.assertRaisesRegex(ValueError, "missing native/oracle"):
            MODULE.compare(log, report)
        log = log.replace("PASS reads=8", "PASS reads=1032") + "\nNIHOS_SDMMC_IDF_ORACLE_SWEEP samples=1024 digest=12345678"
        self.assertEqual(MODULE.compare(log, report)["distributed_samples"], 1024)
        report["sdmmc_sweeps"][2]["digest"] += 1
        with self.assertRaisesRegex(ValueError, "digests differ"):
            MODULE.compare(log, report)


if __name__ == "__main__":
    unittest.main()
