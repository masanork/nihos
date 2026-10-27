#!/usr/bin/env python3
"""Reproducible, sanitizer-enabled read-only FatFs image conformance probes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import runpy
import shlex
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "probes" / "fatfs"


def sha256(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(data)
    return value.hexdigest()


def run(command, *, timeout=30, env=None):
    result = subprocess.run([str(x) for x in command], check=False, capture_output=True,
                            text=True, timeout=timeout, env=env)
    if result.returncode != 0:
        raise RuntimeError(f"Command failed ({result.returncode}): {command}\n{result.stderr}\n{result.stdout}")
    return result


def build(source, work):
    cc = shlex.split(os.environ.get("CC", "cc"))
    flags = ["-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
             "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-D_FILE_OFFSET_BITS=64",
             f"-I{PROBE}", f"-I{source}"]
    binaries = {}
    for kind, main in (("writer", "make_fixture.c"), ("reader", "read_image.c")):
        binary = work / kind
        arguments = [*cc, *flags]
        if kind == "writer":
            arguments.append("-DNIHOS_FIXTURE_WRITER=1")
        arguments += [PROBE / main, PROBE / "host_disk.c", source / "ff.c", source / "ffunicode.c", "-o", binary]
        run(arguments, timeout=120)
        binaries[kind] = binary
    return binaries, run([*cc, "--version"]).stdout.splitlines()[0]


def execute(work, binaries, source, compiler):
    env = os.environ.copy()
    for key in ("NIHOS_FATFS_PATCH_OFFSET", "NIHOS_FATFS_PATCH_HEX", "NIHOS_FATFS_READ_BUDGET"):
        env.pop(key, None)
    env["ASAN_OPTIONS"] = "abort_on_error=1:detect_leaks=" + ("0" if platform.system() == "Darwin" else "1")
    env["UBSAN_OPTIONS"] = "halt_on_error=1:print_stacktrace=1"
    report = {"schema": 1, "scope": "host-only; read-only FatFs image probes, no native/VFS integration or writable durability",
              "compiler": compiler, "host": platform.platform(), "sanitizers": ["address", "undefined"],
              "upstream": {"revision": "R0.16 + official patches 1 and 2", "ff_c_sha256": sha256(source / "ff.c")},
              "sources": {str(p.relative_to(ROOT)): sha256(p) for p in
                          [*sorted(p for p in PROBE.glob("*") if p.is_file()),
                           ROOT / "tools" / "bootstrap-fatfs.py", ROOT / "tools" / "run-fatfs-host.py", ROOT / "provenance.toml"]},
              "fixtures": [], "cases": [], "oracles": []}
    symbols = {line.split()[-1].lstrip("_") for line in run(["nm", binaries["reader"]]).stdout.splitlines() if line.split()}
    # ASan can define its own libc interceptors; only check FatFs API symbols.
    forbidden = {"f_write", "f_mkfs", "f_unlink", "f_rename", "f_truncate", "f_sync", "f_mkdir"} & symbols
    if forbidden:
        raise AssertionError(f"Reader unexpectedly links write APIs: {forbidden}")
    report["reader_forbidden_write_symbols"] = sorted(forbidden)
    fat_oracle = shutil.which("fsck.fat") or shutil.which("fsck_msdos")
    exfat_oracle = shutil.which("fsck.exfat")
    # macOS fsck_exfat needs a block device and cannot check these regular images.
    for tool in (fat_oracle, exfat_oracle):
        if tool:
            report["oracles"].append({"binary": tool, "sha256": sha256(Path(tool))})

    def probe(image, command, path=None, offset=0, amount=0, patch=None, budget=None):
        arguments = [binaries["reader"], image, command]
        if path is not None:
            arguments += [path, str(offset), str(amount)]
        case_env = env.copy()
        if patch is not None:
            case_env["NIHOS_FATFS_PATCH_OFFSET"] = str(patch[0])
            case_env["NIHOS_FATFS_PATCH_HEX"] = patch[1].hex()
        if budget is not None:
            case_env["NIHOS_FATFS_READ_BUDGET"] = str(budget)
        result = run(arguments, timeout=10, env=case_env)
        if result.stderr:
            raise RuntimeError(f"Unexpected reader diagnostics: {result.stderr}")
        value = json.loads(result.stdout)
        if value["disk_writes"] != (1 if command == "disk-write" else 0):
            raise AssertionError("Read-only reader attempted a disk write")
        return value

    def record(name, value, condition, **extra):
        entry = {"name": name, "passed": bool(condition), "observed": value, **extra}
        report["cases"].append(entry)
        (work / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        if not condition:
            raise AssertionError(f"{name}: {value}")

    for kind in ("fat12", "fat16", "fat32", "mbr-fat32", "exfat"):
        image = work / (kind + ".img")
        fixture = json.loads(run([binaries["writer"], image, kind], timeout=120, env=env).stdout)
        initial_hash = sha256(image)
        fixture["sha256_before"] = initial_hash
        fixture["allocated_bytes"] = image.stat().st_blocks * 512
        report["fixtures"].append(fixture)
        value = probe(image, "mount")
        record(kind + ":mount", value, value["status"] == "OK" and value["fs_type"] == fixture["fs_type"])
        value = probe(image, "read", "mEmO.TxT", amount=4096)
        record(kind + ":case-and-eof", value, value["status"] == "OK" and bytes.fromhex(value["hex"]) == b"nihos read-only fixture\n" and value["eof"])
        value = probe(image, "list")
        names = {entry["name"] for entry in value.get("entries", [])}
        record(kind + ":directory", value, value["status"] == "OK" and {"Long filename for alias.txt", "教材", "empty-a.txt", "empty-b.txt"}.issubset(names))
        record(kind + ":max-utf8-name-buffer", {"name_found": "漢" * 251 + ".txt" in names}, "漢" * 251 + ".txt" in names)
        value = probe(image, "read", "a" * 251 + ".txt", amount=10)
        record(kind + ":max-ascii-name", value, value["status"] == "OK" and bytes.fromhex(value["hex"]) == b"max-ascii\n")
        if fixture["alias"]:
            value = probe(image, "read", fixture["alias"], amount=6)
            record(kind + ":short-alias", value, value["status"] == "OK" and bytes.fromhex(value["hex"]) == b"alias\n")
        else:
            record(kind + ":no-short-alias", {"alias": fixture["alias"]}, kind == "exfat")
        for name, expected in (("教材/漢字𠮷.txt", "日本語・か\u3099・𠮷\n".encode()),
                               ("教材/か\u3099.txt", b"decomposed\n"), ("教材/が.txt", b"composed\n")):
            value = probe(image, "read", name, amount=64)
            record(kind + ":unicode:" + name, value, value["status"] == "OK" and bytes.fromhex(value["hex"]) == expected)
        for name in ("empty-a.txt", "empty-b.txt"):
            value = probe(image, "read", name, amount=1)
            record(kind + ":empty:" + name, value, value["status"] == "OK" and value["count"] == 0 and value["size"] == 0 and value["eof"])
        cluster = fixture["cluster_bytes"]
        for boundary in range(1, 8):
            value = probe(image, "read", "fragment.bin", boundary * cluster - 8, 16)
            expected = bytes([0x30 + boundary - 1]) * 8 + bytes([0x30 + boundary]) * 8
            record(kind + f":fragment-boundary:{boundary}", value, value["status"] == "OK" and bytes.fromhex(value["hex"]) == expected)
        value = probe(image, "write-open", "Memo.txt", amount=1)
        record(kind + ":write-policy", value, value["status"] == "ReadOnly" and value["disk_reads"] == 0)
        value = probe(image, "disk-write")
        record(kind + ":block-write-protection", value, value["status"] == "WriteProtected" and value["disk_writes"] == 1)
        value = probe(image, "raw-write-open", "Memo.txt", amount=1)
        record(kind + ":negative-control-write-flag", value, value["status"] == "OK",
               interpretation="Upstream read-only build masks FA_WRITE; the outer VFS must reject write requests explicitly")
        value = probe(image, "mount", budget=0)
        record(kind + ":io-budget", value, value["status"] == "MountError" and value["budget_exhaustions"] > 0)
        value = probe(image, "mount", patch=(fixture["volume_byte"] + 510, b"\x00\x00"))
        record(kind + ":invalid-boot-signature", value, value["status"] == "MountError")
        if kind == "fat12":
            value = probe(image, "raw-mount", patch=(510, bytes(2)))
            record(kind + ":negative-control-boot-signature", value, value["status"] == "OK",
                   interpretation="Upstream FatFs accepts this unsigned FAT VBR; strict outer boot policy rejects it")

        if kind in ("fat32", "mbr-fat32"):
            value = probe(image, "mount", patch=(fixture["volume_byte"] + 36, struct.pack("<I", 0x200000)))
            record(kind + ":oversized-fat-bpb", value, value["status"] == "MountError")
            entry = fixture["fat_byte"] + fixture["fragment_first_cluster"] * 4
            value = probe(image, "read", "fragment.bin", cluster, 16, patch=(entry, struct.pack("<I", 0x0ffffff0)))
            record(kind + ":invalid-cluster-link", value, value["status"] == "Error")
            value = probe(image, "read", "fragment.bin", cluster, 16,
                          patch=(entry, struct.pack("<I", fixture["fragment_first_cluster"])))
            record(kind + ":negative-control-cluster-cycle", value,
                   value["status"] == "OK" and bytes.fromhex(value["hex"]) == b"0" * 16,
                   interpretation="FatFs does not validate this chain cycle; bounded reading can repeat data. Not general corrupted-volume qualification")
        if kind == "mbr-fat32":
            value = probe(image, "mount", patch=(446 + 8, struct.pack("<I", fixture["image_bytes"] // 512)))
            record(kind + ":partition-outside-device", value, value["status"] == "MountError" and value["out_of_range"] == 0)
            value = probe(image, "mount", patch=(446 + 4, b"\xee"))
            record(kind + ":gpt-rejected", value, value["status"] == "MountError")
            value = probe(image, "mount", patch=(fixture["volume_byte"] + 32, struct.pack("<I", fixture["image_bytes"] // 512)))
            record(kind + ":volume-outside-partition", value, value["status"] == "MountError" and value["out_of_range"] == 0)
        if kind == "exfat":
            for index, offset in enumerate((0x7ffffff8, 0xfffffff8, 0x100001ff0)):
                value = probe(image, "read", "large.bin", offset, 16)
                expected = bytes(range(0xa0 + index * 16, 0xb0 + index * 16))
                record(kind + f":large-offset:{offset}", value, value["status"] == "OK" and value["size"] == fixture["big_size"] and bytes.fromhex(value["hex"]) == expected)
            value = probe(image, "read", "large.bin", fixture["big_size"], 16)
            record(kind + ":large-eof", value, value["status"] == "OK" and value["count"] == 0 and value["eof"])
            value = probe(image, "mount", patch=(fixture["volume_byte"] + 92, bytes(4)))
            record(kind + ":zero-exfat-clusters", value, value["status"] == "MountError")
        oracle = exfat_oracle if kind == "exfat" else fat_oracle if kind != "mbr-fat32" else None
        if oracle:
            checked = run([oracle, "-n", image], timeout=60)
            record(kind + ":independent-fsck", {"tool": oracle, "stdout": checked.stdout, "stderr": checked.stderr}, True)
        fixture["sha256_after"] = sha256(image)
        record(kind + ":image-unchanged", {"sha256": fixture["sha256_after"]}, initial_hash == fixture["sha256_after"])
        print(f"{kind}: PASS ({fixture['allocated_bytes']} allocated / {fixture['image_bytes']} logical bytes)", flush=True)
    report["passed"] = True
    report["case_count"] = len(report["cases"])
    (work / "results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out-dir", type=Path, default=ROOT / "build" / "fatfs-host")
    parser.add_argument("--require-oracles", action="store_true", help="Require fsck.fat and fsck.exfat (Linux CI)")
    args = parser.parse_args()
    if args.require_oracles and not (shutil.which("fsck.fat") and shutil.which("fsck.exfat")):
        parser.error("--require-oracles needs dosfstools and exfatprogs")
    args.out_dir.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="run-", dir=args.out_dir)).resolve()
    print(f"Artifacts: {work}", flush=True)
    try:
        source = runpy.run_path(str(ROOT / "tools" / "bootstrap-fatfs.py"))["bootstrap"]()
        binaries, compiler = build(source, work)
        report = execute(work, binaries, source, compiler)
    except Exception as error:
        (work / "failure.json").write_text(json.dumps({"error": str(error)}, ensure_ascii=False, indent=2) + "\n")
        raise
    (args.out_dir / "latest.json").write_text(json.dumps({"results": str(work / "results.json")}, indent=2) + "\n")
    print(f"FatFs read-only host PASS: {report['case_count']} cases; ASan/UBSan; no image changes")


if __name__ == "__main__":
    main()
