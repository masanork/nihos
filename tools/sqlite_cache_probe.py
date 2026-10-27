#!/usr/bin/env python3
"""Compare cache budgets and sweep persistent SQLite allocator failures."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
from stream_probe import CAPACITY, PAGE, copy_range, create_image, require

PAYLOAD_START = CAPACITY - 32768 * PAGE


def main():
    host_source, bounded_source, output = map(Path, sys.argv[1:])
    output = output.resolve()
    require(output.is_dir() and not any(output.iterdir()), "output must be new and empty")
    host = output / "sqlite-cache-probe"
    bounded = output / "sqlite-bounded-probe"
    shutil.copy2(host_source, host)
    shutil.copy2(bounded_source, bounded)
    result = {"schema": 1, "evidence": "host-persistent-SQLite-cache-and-bounded-OOM", "physical_power_cuts": 0,
              "binary_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in (host, bounded)},
              "commands": [], "profiles": [], "oom_points": [], "passed": False}

    def run(binary, command, image, profile, expected_failure=False, log_command=True):
        completed = subprocess.run([str(binary), command, str(image), profile], capture_output=True, text=True, timeout=180)
        info = json.loads(completed.stdout)
        entry = {"binary": binary.name, "command": command, "image": image.name, "profile": profile,
                 "exit_code": completed.returncode, "result": info, "stderr": completed.stderr}
        if log_command:
            result["commands"].append(entry)
        require(info["allocator_clean"], f"allocator cleanup failed: {entry}")
        if not expected_failure:
            require(completed.returncode == 0, f"{command}/{profile} failed: {completed.stderr}")
        return entry

    def snapshot(image, label, high_water):
        saved = {"capacity": CAPACITY, "ranges": []}
        fd = os.open(image, os.O_RDONLY)
        try:
            require(os.pread(fd, 16 * PAGE, CAPACITY - 16 * PAGE) == bytes(16 * PAGE), "reserve modified")
            for name, offset, size in ((label + "-metadata.bin", 0, 258 * PAGE),
                                       (label + "-payload.bin", PAYLOAD_START, high_water * PAGE)):
                saved["ranges"].append({"file": name, "offset": offset, "bytes": size,
                                        "sha256": copy_range(fd, offset, size, output / name)})
        finally:
            os.close(fd)
        return saved

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
                        require(os.pwrite(fd, data, item["offset"] + position) == len(data), "short restore")
                        position += len(data)
                require(position == item["bytes"] and digest.hexdigest() == item["sha256"], "range mismatch")
            os.fsync(fd)
        finally:
            os.close(fd)
        return image

    def export(binary, image, name, rows):
        path = output / name
        run(binary, "export-db", image, str(path))
        with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as db:
            actual = db.execute("SELECT count(*),sum(version) FROM records").fetchone()
            require(actual == (rows, rows), "wrong exported SQL state")
            require(db.execute("SELECT version FROM marker").fetchone()[0] == 1, "wrong marker")
            require(db.execute("PRAGMA integrity_check").fetchone()[0] == "ok", "export integrity failure")
        return {"file": path.name, "bytes": path.stat().st_size, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}

    try:
        bounded_baseline = None
        bounded_update = None
        for suffix, rows in (("", 64), ("-large", 640)):
            exports = []
            for profile in ("host32", "host512", "pool512"):
                name = profile + suffix
                binary = bounded if profile == "pool512" else host
                image = output / (name + ".img")
                create_image(image)
                seed = run(binary, "seed", image, name)["result"]
                old = run(binary, "verify-old", image, name)["result"]
                baseline = snapshot(image, name + "-baseline", old["payload_high_water_pages"])
                changed = run(binary, "update", image, name)["result"]
                verified = run(binary, "verify-new", image, name)["result"]
                require(verified["checked_version"] == 1, "new SQL state was not verified")
                if profile == "pool512":
                    require(seed["bounded_allocator"] and changed["allocator_rejected"] == 0 and seed["allocator_rejected"] == 0, "bounded baseline rejected allocation")
                    require(seed["allocator_reserved_bytes"] <= 81920 and seed["pagecache_bytes"] == 524288, "bounded budget grew")
                detached = export(binary, image, name + ".sqlite", rows)
                exports.append(detached["sha256"])
                committed = snapshot(image, name + "-committed", verified["payload_high_water_pages"])
                rebuilt = restore(name + "-reconstructed", committed)
                run(binary, "verify-new", rebuilt, name)
                result["profiles"].append({"profile": name, "rows": rows, "seed": seed, "update": changed,
                                           "export": detached, "baseline_snapshot": baseline, "committed_snapshot": committed})
                if profile == "pool512" and not suffix:
                    bounded_baseline, bounded_update = baseline, changed
                print(json.dumps({"progress": "profile", "name": name, "writes": changed["writes"], "syncs": changed["syncs"]}), flush=True)
            require(len(set(exports)) == 1, "cache/allocator profiles produced different DB bytes")
        edge_image = restore("allocator-edges", bounded_baseline)
        edges = run(bounded, "allocator-selftest", edge_image, "pool512")
        require(edges["result"]["allocator_rejected"] >= 2, "large scratch slot did not enforce simultaneous-allocation bound")
        run(bounded, "verify-old", edge_image, "pool512")
        result["allocator_edge_test"] = edges
        # The ZERO_MALLOC binary must not silently route a host profile to libc.
        no_fallback = restore("no-fallback", bounded_baseline)
        failure = run(bounded, "update", no_fallback, "host512", expected_failure=True)
        require(failure["exit_code"] != 0 and failure["result"]["sqlite_error"] & 255 == 7, "ZERO_MALLOC admitted a hidden fallback")
        run(bounded, "verify-old", no_fallback, "pool512")
        result["no_libc_fallback_counterexample"] = failure
        # Inject exactly one NULL at every baseline malloc/realloc call. Each
        # fresh process must clean up all blocks and return its parent span.
        count = bounded_update["allocator_attempts"]
        require(0 < count < 5000, "unexpected allocator sweep size")
        for point in range(count):
            image = restore("oom", bounded_baseline)
            failed = run(bounded, "update", image, f"pool512:{point}", expected_failure=True, log_command=False)
            info = failed["result"]
            require(info["allocator_injected"] == 1, f"injection not reached at {point}")
            require(failed["exit_code"] == 0 or info["sqlite_error"] & 255 == 7, f"non-NOMEM allocator failure at {point}: {failed}")
            recovered = run(bounded, "verify-either", image, "pool512", log_command=False)
            version = recovered["result"]["checked_version"]
            require(version in (0, 1), "recovery was neither old nor new")
            if info["sql_committed"] or failed["exit_code"] == 0:
                require(version == 1, "successful SQL COMMIT did not persist")
            result["oom_points"].append({"point": point, "update": failed, "recovered": recovered})
            image.unlink()  # only the generated, fully verified iteration image
            if point % 25 == 0 or point + 1 == count:
                print(json.dumps({"progress": "OOM", "completed": point + 1, "total": count}), flush=True)
        result["oom_summary"] = {"points": count, "all_injected_once": True, "all_allocators_clean": True,
                                 "all_recover_old_or_new": True,
                                 "probe_successes": sum(x["update"]["exit_code"] == 0 for x in result["oom_points"]),
                                 "probe_NOMEM_returns": sum(x["update"]["exit_code"] != 0 for x in result["oom_points"]),
                                 "SQL_commit_successes": sum(x["update"]["result"]["sql_committed"] for x in result["oom_points"]),
                                 "all_successful_SQL_commits_preserved": True,
                                 "recovered_old": sum(x["recovered"]["result"]["checked_version"] == 0 for x in result["oom_points"]),
                                 "recovered_new": sum(x["recovered"]["result"]["checked_version"] == 1 for x in result["oom_points"])}
        result["processes"] = len(result["commands"]) + 2 * len(result["oom_points"])
        result["passed"] = True
    finally:
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(output / "results.json", flush=True)


if __name__ == "__main__":
    main()
