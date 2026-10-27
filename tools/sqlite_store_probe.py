#!/usr/bin/env python3
"""Actual SQLite/PERSIST through the copied service: recovery and sync controls."""
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import sqlite3
import subprocess
import sys
from stream_probe import CAPACITY, PAGE, copy_range, create_image, require

PAYLOAD_START = CAPACITY - 32768 * PAGE


def main():
    binary_source, output = map(Path, sys.argv[1:3])
    mutant_source = Path(sys.argv[3]) if len(sys.argv) > 3 else None
    output = output.resolve()
    require(output.is_dir() and not any(output.iterdir()), "output must be new and empty")
    binary = output / "sqlite-store-probe"
    shutil.copy2(binary_source, binary)
    result = {"schema": 1, "evidence": "host-real-SQLite-managed-PERSIST-service-VFS", "physical_power_cuts": 0,
              "capacity": CAPACITY, "detached_oracle_sqlite_version": sqlite3.sqlite_version, "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "commands": [], "cases": [], "negative_controls": [], "passed": False}

    def run(command, image, extra=(), expect_fail=False):
        completed = subprocess.run([str(binary), command, str(image), *map(str, extra)], capture_output=True, text=True, timeout=180)
        result["commands"].append({"command": command, "image": image.name, "exit_code": completed.returncode,
                                   "stdout": completed.stdout, "stderr": completed.stderr})
        if expect_fail:
            require(completed.returncode != 0 and "SCALAR_MISMATCH" in completed.stderr, "sync omission did not expose false durable success")
            return completed
        require(completed.returncode == 0, f"{command} failed: {completed.stderr}")
        info = json.loads(completed.stdout)
        require(info["sqlite_version"] == "3.54.1", "unexpected SQLite source version")
        require(info["store_bytes"] + info["owner_bytes"] + info["queue_bytes"] < 2 * 1024**2, "store buffer envelope exceeded")
        return info

    def kill_ready(command, image, executable=binary):
        process = subprocess.Popen([str(executable), command, str(image)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                require(selector.select(timeout=180), "readiness timeout")
            line = process.stdout.readline()
            require(line, f"{command} died before readiness")
            info = json.loads(line)
            require(info["phase"] == command, "unexpected readiness")
            process.kill()
            stdout, stderr = process.communicate(timeout=30)
            result["commands"].append({"command": command, "binary": executable.name, "image": image.name,
                                       "exit_code": process.returncode, "pid": process.pid, "readiness": info,
                                       "stdout": stdout, "stderr": stderr})
            require(process.returncode == -9, "owned child did not stop")
            return info
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=30)

    def snapshot(image, label, high_water):
        ranges = []
        fd = os.open(image, os.O_RDONLY)
        try:
            require(os.pread(fd, 16 * PAGE, CAPACITY - 16 * PAGE) == bytes(16 * PAGE), "reserve modified")
            for name, offset, length in ((label + "-metadata.bin", 0, 258 * PAGE),
                                          (label + "-payload.bin", PAYLOAD_START, high_water * PAGE)):
                ranges.append({"file": name, "offset": offset, "bytes": length,
                               "sha256": copy_range(fd, offset, length, output / name)})
        finally:
            os.close(fd)
        return {"capacity": CAPACITY, "ranges": ranges, "omitted_bytes": "zero sparse holes"}

    def restore(name, saved):
        image = output / (name + ".img")
        create_image(image)
        fd = os.open(image, os.O_RDWR)
        try:
            for item in saved["ranges"]:
                position = 0
                digest = hashlib.sha256()
                with (output / item["file"]).open("rb") as source:
                    while data := source.read(65536):
                        digest.update(data)
                        require(os.pwrite(fd, data, item["offset"] + position) == len(data), "short range restore")
                        position += len(data)
                require(position == item["bytes"] and digest.hexdigest() == item["sha256"], "snapshot mismatch")
            os.fsync(fd)
        finally:
            os.close(fd)
        return image

    def check_export(path, version):
        # A deliberately detached copy omits the managed rollback journal.
        with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as db:
            actual = db.execute("SELECT count(*),sum(version) FROM records").fetchone()
            marker = db.execute("SELECT version FROM marker").fetchone()[0]
            integrity = db.execute("PRAGMA integrity_check").fetchone()[0]
        require(actual == (64, 64 * version) and marker == version and integrity == "ok", "unexpected detached DB contents")
        return {"records": actual[0], "sum_version": actual[1], "marker": marker, "integrity": integrity,
                "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

    try:
        image = output / "seed.img"
        create_image(image)
        seeded = run("seed", image)
        verified = run("verify-old", image)
        result["baseline_snapshot"] = snapshot(image, "baseline", verified["payload_high_water_pages"])
        result["cases"].append({"name": "real_SQLite_64_rows_4096_page_PERSIST_FULL_reopens", "passed": True, "seed": seeded})
        rollback_image = restore("rollback", result["baseline_snapshot"])
        run("rollback", rollback_image)
        run("verify-old", rollback_image)
        result["cases"].append({"name": "explicit_SQL_rollback_preserves_records_and_marker", "passed": True})
        full_image = restore("quota", result["baseline_snapshot"])
        full = run("quota-full", full_image)
        require(full["sqlite_error"] == 13, "SQLite page quota did not return SQLITE_FULL")
        run("verify-old", full_image)
        result["cases"].append({"name": "real_SQLITE_FULL_page_quota_rolls_back_and_reopens", "passed": True, "quota": full})
        journal_image = restore("journal-cut", result["baseline_snapshot"])
        journal = kill_ready("journal-sync-wait", journal_image)
        run("verify-old", journal_image)
        result["cases"].append({"name": "kill_after_journal_sync_keeps_SQL_transaction_old", "passed": True, "cut": journal})
        db_image = restore("db-cut", result["baseline_snapshot"])
        db_cut = kill_ready("db-sync-wait", db_image)
        require(db_cut["journal_hot"] and not db_cut["sql_committed"], "DB cut was not before journal invalidation")
        before = output / "db-before-recovery.sqlite"
        run("export-db", db_image, (before,))
        detached_new = check_export(before, 1)
        recovered = run("verify-old", db_image)
        after = output / "db-after-recovery.sqlite"
        run("export-db", db_image, (after,))
        detached_old = check_export(after, 0)
        result["cases"].append({"name": "real_hot_journal_reverts_durable_new_DB_to_old_transaction", "passed": True,
                                 "cut": db_cut, "detached_before": detached_new, "detached_after": detached_old,
                                 "recovered": recovered})
        ack_image = restore("ack-cut", result["baseline_snapshot"])
        ack = kill_ready("commit-wait", ack_image)
        require(ack["sql_committed"] and not ack["journal_hot"], "SQLite success preceded journal invalidation")
        newest = run("verify-new", ack_image)
        result["cases"].append({"name": "kill_after_SQL_COMMIT_success_preserves_all_changes", "passed": True, "ack": ack})
        error_image = restore("sync-error", result["baseline_snapshot"])
        error = run("sync-error", error_image)
        require(error["sqlite_error"] == 10 and error["unknown_publications"] == 1 and error["recovery_required"], "sync failure did not stop SQLite/service")
        run("verify-old", error_image)
        result["cases"].append({"name": "device_sync_failure_reaches_SQLITE_IOERR_and_stops_binding", "passed": True, "error": error})
        result["committed_snapshot"] = snapshot(ack_image, "committed", newest["payload_high_water_pages"])
        rebuilt = restore("reconstructed", result["committed_snapshot"])
        run("verify-new", rebuilt)
        result["cases"].append({"name": "compact_range_reconstruction_reopens_committed_SQLite", "passed": True})
        if mutant_source:
            mutant = output / "sqlite-store-no-sync"
            shutil.copy2(mutant_source, mutant)
            negative_image = restore("negative-sync", result["baseline_snapshot"])
            false_ack = kill_ready("commit-wait", negative_image, mutant)
            require(false_ack["sql_committed"], "negative control never reached SQLite success")
            failure = run("verify-new", negative_image, expect_fail=True)
            run("verify-old", negative_image)
            result["negative_controls"].append({"variant": "omit_all_VFS_sync_callbacks", "semantic_counterexample_found": True,
                                                 "false_success": false_ack, "verification_exit_code": failure.returncode,
                                                 "binary_sha256": hashlib.sha256(mutant.read_bytes()).hexdigest()})
        result["images"] = {p.name: {"bytes": p.stat().st_size, "allocated_bytes": p.stat().st_blocks * 512}
                            for p in output.glob("*.img")}
        require(all(x["bytes"] == CAPACITY and x["allocated_bytes"] < 128 * 1024**2 for x in result["images"].values()), "lost sparse allocation")
        result["passed"] = True
    finally:
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(output / "results.json")


if __name__ == "__main__":
    main()
