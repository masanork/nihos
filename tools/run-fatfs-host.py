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
        arguments += [PROBE / main, PROBE / "host_disk.c", source / "ff.c" if kind == "writer" else PROBE / "safety.c", source / "ffunicode.c", "-o", binary]
        run(arguments, timeout=120)
        binaries[kind] = binary
    return binaries, run([*cc, "--version"]).stdout.splitlines()[0]


def execute(work, binaries, source, compiler):
    env = os.environ.copy()
    for key in ("NIHOS_FATFS_PATCH_OFFSET", "NIHOS_FATFS_PATCH_HEX", "NIHOS_FATFS_READ_BUDGET", "NIHOS_FATFS_CHAIN_BUDGET", "NIHOS_FATFS_CANCEL_AFTER"):
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

    def probe(image, command, path=None, offset=0, amount=0, patch=None, budget=None, chain_budget=None, cancel_after=None):
        arguments = [binaries["reader"], image, command]
        if path is not None:
            arguments += [path, str(offset), str(amount)]
        case_env = env.copy()
        if patch is not None:
            case_env["NIHOS_FATFS_PATCH_OFFSET"] = str(patch[0])
            case_env["NIHOS_FATFS_PATCH_HEX"] = patch[1].hex()
        if budget is not None:
            case_env["NIHOS_FATFS_READ_BUDGET"] = str(budget)
        if chain_budget is not None:
            case_env["NIHOS_FATFS_CHAIN_BUDGET"] = str(chain_budget)
        if cancel_after is not None:
            case_env["NIHOS_FATFS_CANCEL_AFTER"] = str(cancel_after)
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

    def fat_entry(image, fixture, cluster, replacement=None):
        fmt = fixture["fs_type"]
        width = 2 if fmt in (1, 2) else 4
        offset = fixture["fat_byte"] + (cluster + cluster // 2 if fmt == 1 else cluster * width)
        with image.open("rb") as stream:
            stream.seek(offset)
            raw = int.from_bytes(stream.read(width), "little")
        if replacement is None:
            return ((raw >> 4 if cluster % 2 else raw) & 0xfff) if fmt == 1 else raw & (0xffff if fmt == 2 else 0x0fffffff if fmt == 3 else 0x7fffffff)
        if fmt == 1:
            replacement = ((raw & 0x000f) | ((replacement & 0xfff) << 4)) if cluster % 2 else ((raw & 0xf000) | (replacement & 0xfff))
        return offset, replacement.to_bytes(width, "little")

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
        a = probe(image, "identity", "empty-a.txt")
        b = probe(image, "identity", "empty-b.txt")
        again = probe(image, "identity", "EMPTY-A.TXT")
        record(kind + ":empty-identities", {"a": a, "b": b, "case_alias": again},
               a["status"] == b["status"] == again["status"] == "OK" and a["data_cluster"] == b["data_cluster"] == 0 and
               a["identity"] != b["identity"] and a["identity"] == again["identity"])
        if fixture["empty_alias"]:
            original = probe(image, "identity", "Long empty filename.txt")
            alias = probe(image, "identity", fixture["empty_alias"])
            record(kind + ":empty-long-short-identity", {"lfn": original, "sfn": alias},
                   original["status"] == alias["status"] == "OK" and original["identity"] == alias["identity"])
        original = probe(image, "identity", "Long filename for alias.txt")
        alias = probe(image, "identity", fixture["alias"] or "LONG FILENAME FOR ALIAS.TXT")
        record(kind + ":long-alias-identity", {"lfn": original, "alias": alias},
               original["status"] == alias["status"] == "OK" and original["identity"] == alias["identity"])
        nested = probe(image, "identity", "教材/Memo.txt")
        root_memo = probe(image, "identity", "Memo.txt")
        record(kind + ":parent-directory-identity", {"nested": nested, "root": root_memo},
               nested["status"] == root_memo["status"] == "OK" and nested["identity"] != root_memo["identity"])
        composed = probe(image, "identity", "教材/が.txt")
        decomposed = probe(image, "identity", "教材/か\u3099.txt")
        record(kind + ":unicode-normalization-identity", {"composed": composed, "decomposed": decomposed},
               composed["status"] == decomposed["status"] == "OK" and composed["identity"] != decomposed["identity"])
        cluster = fixture["cluster_bytes"]
        for boundary in range(1, 8):
            value = probe(image, "read", "fragment.bin", boundary * cluster - 8, 16)
            expected = bytes([0x30 + boundary - 1]) * 8 + bytes([0x30 + boundary]) * 8
            record(kind + f":fragment-boundary:{boundary}", value, value["status"] == "OK" and bytes.fromhex(value["hex"]) == expected)
        first = fixture["fragment_first_cluster"]
        second = fat_entry(image, fixture, first)
        for label, mutated, replacement in (("self-cycle", first, first), ("two-node-cycle", second, first),
                                            ("short-chain", first, {1: 0xfff, 2: 0xffff, 3: 0x0fffffff, 4: 0xffffffff}[fixture["fs_type"]])):
            value = probe(image, "read", "fragment.bin", 0, 16, patch=fat_entry(image, fixture, mutated, replacement))
            record(kind + ":guard:" + label, value, value["status"] == "Corrupt" and value["count"] == 0 and value["guard_steps"] < 64)
        if fixture["root_cluster"]:
            value = probe(image, "list", patch=fat_entry(image, fixture, fixture["root_cluster"], fixture["root_cluster"]))
            record(kind + ":guard:root-cycle", value, value["status"] == "Corrupt" and value["guard_steps"] < 64)
        if kind != "exfat":
            child = fixture["child_cluster"]
            value = probe(image, "read", "教材/漢字𠮷.txt", 0, 16, patch=fat_entry(image, fixture, child, child))
            record(kind + ":guard:parent-cycle", value, value["status"] == "Corrupt" and value["count"] == 0)
            with image.open("rb") as stream:
                stream.seek(fixture["child_entry_byte"])
                entry_bytes = bytearray(stream.read(32))
            entry_bytes[20:22] = struct.pack("<H", fixture["root_cluster"] >> 16)
            entry_bytes[26:28] = struct.pack("<H", fixture["root_cluster"] & 0xffff)
            value = probe(image, "read", "教材/Memo.txt", 0, 16, patch=(fixture["child_entry_byte"], bytes(entry_bytes)))
            record(kind + ":guard:directory-ancestor-alias", value, value["status"] == "Corrupt" and value["count"] == 0)
        value = probe(image, "read", "fragment.bin", 0, 16, chain_budget=3)
        record(kind + ":guard:budget", value, value["status"] == "BudgetExceeded" and value["count"] == 0 and value["guard_steps"] == 3)
        value = probe(image, "read", "fragment.bin", 0, 16, cancel_after=3)
        record(kind + ":guard:cancel", value, value["status"] == "Cancelled" and value["count"] == 0 and value["guard_steps"] == 3)
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
            record(kind + ":invalid-cluster-link", value, value["status"] == "Corrupt" and value["count"] == 0)
            value = probe(image, "raw-read", "fragment.bin", cluster, 16,
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
            root_byte = fixture["data_byte"] + (fixture["root_cluster"] - 2) * cluster
            with image.open("rb") as stream:
                stream.seek(root_byte)
                root_entries = stream.read(cluster)
            block = None
            for position in range(0, len(root_entries) - 64, 32):
                if root_entries[position] != 0x85 or not (root_entries[position + 4] & 0x10):
                    continue
                if struct.unpack_from("<I", root_entries, position + 52)[0] != fixture["child_cluster"]:
                    continue
                length = (root_entries[position + 1] + 1) * 32
                block = bytearray(root_entries[position:position + length])
                assert len(block) == length
                struct.pack_into("<I", block, 52, fixture["root_cluster"])
                checksum = 0
                for index, byte in enumerate(block):
                    if index not in (2, 3):
                        checksum = (((checksum >> 1) | ((checksum & 1) << 15)) + byte) & 0xffff
                struct.pack_into("<H", block, 2, checksum)
                patch = (root_byte + position, bytes(block))
                break
            assert block is not None, "fixture child directory entry not found"
            value = probe(image, "raw-read", "教材/Memo.txt", 0, 16, patch=patch)
            record(kind + ":negative-control-directory-alias", value, value["status"] == "OK" and bytes.fromhex(value["hex"]) == b"nihos read-only fixture\n"[:16])
            value = probe(image, "read", "教材/Memo.txt", 0, 16, patch=patch)
            record(kind + ":guard:directory-ancestor-alias", value, value["status"] == "Corrupt" and value["count"] == 0)
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
        bootstrap = runpy.run_path(str(ROOT / "tools" / "bootstrap-fatfs.py"))
        cache = work / "fatfs"
        cache.mkdir()
        for name, _, expected in bootstrap["INPUTS"]:
            cached = ROOT / ".tools" / "fatfs-r016-p2" / name
            if cached.is_file() and sha256(cached) == expected:
                shutil.copyfile(cached, cache / name)
        source = bootstrap["bootstrap"](cache)
        binaries, compiler = build(source, work)
        report = execute(work, binaries, source, compiler)
    except Exception as error:
        (work / "failure.json").write_text(json.dumps({"error": str(error)}, ensure_ascii=False, indent=2) + "\n")
        raise
    (args.out_dir / "latest.json").write_text(json.dumps({"results": str(work / "results.json")}, indent=2) + "\n")
    print(f"FatFs read-only host PASS: {report['case_count']} cases; ASan/UBSan; no image changes")


if __name__ == "__main__":
    main()
