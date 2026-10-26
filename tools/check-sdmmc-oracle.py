#!/usr/bin/env python3
"""Compare a validated physical native SDMMC report with independent IDF reads."""
import json
from pathlib import Path
import re
import sys


def compare(log, native):
    log = log.replace("\r", "")
    if (log.count("NIHOS_SDMMC_IDF_ORACLE_BEGIN read_only=1 width=1 khz=400") != 1 or
            log.count("NIHOS_SDMMC_IDF_ORACLE_PASS reads=8 writes=0") != 1 or
            any(word in log for word in ("abort()", "panic", "Guru Meditation"))):
        raise ValueError("incomplete or failed IDF oracle")
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
    return {"passed": True, "sectors": sectors, "lbas": lbas, "crcs": crcs,
            "native_elf_sha256": native["image_elf_sha256"], "oracle_reads": 8, "native_reads": sd["reads"]}


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
