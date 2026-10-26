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


if __name__ == "__main__":
    unittest.main()
