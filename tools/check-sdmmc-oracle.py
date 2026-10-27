#!/usr/bin/env python3
"""Compare a validated physical native SDMMC report with independent IDF reads."""
import json
from pathlib import Path
import re
import sys


def compare(log, native):
    log = log.replace("\r", "")
    modes = re.findall(r"NIHOS_SDMMC_IDF_ORACLE_BEGIN read_only=1 width=([14]) khz=(400|20000)\n", log)
    totals = re.findall(r"NIHOS_SDMMC_IDF_ORACLE_PASS reads=(\d+) writes=0", log)
    if (len(modes) != 1 or log.count("NIHOS_SDMMC_IDF_ORACLE_BEGIN") != 1 or
            len(totals) != 1 or log.count("NIHOS_SDMMC_IDF_ORACLE_PASS") != 1 or
            any(word in log for word in ("abort()", "panic", "Guru Meditation"))):
        raise ValueError("incomplete or failed IDF oracle")
    width, khz = map(int, modes[0])
    if (width, khz) not in ((1, 400), (4, 400), (4, 20000)):
        raise ValueError("unsupported oracle transport")
    configured = re.findall(r"NIHOS_SDMMC_IDF_ORACLE_CONFIG width=(\d+) khz=(\d+)", log)
    if configured or width == 4:
        if len(configured) != 1 or tuple(map(int, configured[0])) != (width, khz):
            raise ValueError("oracle working bus configuration differs")
    cards = re.findall(r"NIHOS_SDMMC_IDF_ORACLE_CARD sectors=(\d+)", log)
    if len(cards) != 1:
        raise ValueError("missing/duplicate oracle capacity")
    sectors = int(cards[0])
    reads = re.findall(r"NIHOS_SDMMC_IDF_ORACLE_READ pass=([01]) lba=([0-9a-f]{8}) crc=([0-9a-f]{8}) tail=[0-9a-f]{4}", log)
    lbas = [0, 1, sectors // 2, sectors - 1]
    if len(reads) != 8 or log.count("NIHOS_SDMMC_IDF_ORACLE_READ ") != 8:
        raise ValueError("incomplete oracle reads")
    for i, (iteration, lba, _) in enumerate(reads):
        if int(iteration) != i // 4 or int(lba, 16) != lbas[i % 4]:
            raise ValueError("unexpected oracle read sequence")
    crcs = [int(row[2], 16) for row in reads[:4]]
    if crcs != [int(row[2], 16) for row in reads[4:]]:
        raise ValueError("unstable oracle data")
    sd = native.get("sdmmc")
    if native.get("evidence") != "physical-device" or sd is None:
        raise ValueError("requires a validated physical native SDMMC report")
    if sectors != sd["sectors_low"] + (sd["sectors_high"] << 32):
        raise ValueError("oracle and native capacities differ")
    if crcs != [sd[name] for name in ("crc0", "crc1", "crc_middle", "crc_last")]:
        raise ValueError("oracle and native sector CRCs differ")
    sweeps = re.findall(r"NIHOS_SDMMC_IDF_ORACLE_SWEEP samples=(\d+) digest=([0-9a-f]{8})", log)
    native_sweeps = native.get("sdmmc_sweeps", [])
    samples = 0
    digest = None
    if sweeps or native_sweeps:
        if len(sweeps) != 1 or log.count("NIHOS_SDMMC_IDF_ORACLE_SWEEP") != 1 or not native_sweeps:
            raise ValueError("missing native/oracle distributed sweep")
        samples, digest = int(sweeps[0][0]), int(sweeps[0][1], 16)
        if samples != 1024 or any(row["samples"] != samples or row["digest"] != digest for row in native_sweeps):
            raise ValueError("oracle and native distributed digests differ")
    if int(totals[0]) != 8 + samples:
        raise ValueError("oracle total read count differs")
    return {"passed": True, "sectors": sectors, "lbas": lbas, "crcs": crcs,
            "oracle_bus_bits": width, "oracle_clock_khz": khz,
            "distributed_samples": samples, "distributed_digest": digest,
            "native_elf_sha256": native["image_elf_sha256"], "oracle_reads": 8 + samples, "native_reads": sd["reads"]}


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: check-sdmmc-oracle.py IDF.log NATIVE-REPORT.json COMPARISON.json")
    try:
        result = compare(Path(sys.argv[1]).read_text(), json.loads(Path(sys.argv[2]).read_text()))
    except ValueError as error:
        raise SystemExit("SDMMC oracle comparison failed: " + str(error)) from error
    Path(sys.argv[3]).write_text(json.dumps(result, indent=2) + "\n")
    print("SDMMC native/IDF capacity and all four sector CRCs match")


if __name__ == "__main__":
    main()
