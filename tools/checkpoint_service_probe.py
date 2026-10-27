#!/usr/bin/env python3
"""Owned service requests across client exit, process loss and sparse recovery."""
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
from stream_probe import CAPACITY, PAGE, copy_range, create_image, require


def main():
    source, output = map(Path, sys.argv[1:])
    output = output.resolve()
    require(output.is_dir() and not any(output.iterdir()), "output must be new and empty")
    binary = output / "service-probe"
    shutil.copy2(source, binary)
    image = output / "volume.img"
    result = {"schema": 1, "evidence": "host-owned-store-service", "physical_power_cuts": 0,
              "capacity": CAPACITY, "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "commands": [], "cases": [], "passed": False}

    def run(command, path=image):
        completed = subprocess.run([str(binary), command, str(path)], capture_output=True, text=True, timeout=120)
        result["commands"].append({"command": command, "image": path.name, "exit_code": completed.returncode,
                                   "stdout": completed.stdout, "stderr": completed.stderr})
        require(completed.returncode == 0, f"{command} failed: {completed.stderr}")
        info = json.loads(completed.stdout)
        require(info["store_bytes"] + info["owner_bytes"] + info["queues_bytes"] <= 2 * 1024**2, "service buffers exceed envelope")
        return info

    def kill_ready(command, generation):
        process = subprocess.Popen([str(binary), command, str(image)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                require(selector.select(timeout=120), "readiness timeout")
            line = process.stdout.readline()
            require(line, f"{command} died before readiness")
            info = json.loads(line)
            require(info["phase"] == command and info["generation"] == generation, "bad readiness")
            process.kill()
            stdout, stderr = process.communicate(timeout=30)
            result["commands"].append({"command": command, "exit_code": process.returncode, "pid": process.pid,
                                       "readiness": info, "stdout": stdout, "stderr": stderr})
            require(process.returncode == -9, "owned child did not stop")
            return info
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=30)

    try:
        create_image(image)
        seeded = run("seed")
        run("verify-old")
        result["cases"].append({"name": "two_existing_objects_reopen_through_service", "passed": True, "seed": seeded})
        staged = kill_ready("stage-wait", 3)
        run("verify-old")
        result["cases"].append({"name": "kill_after_staged_ack_keeps_old_generation", "passed": True, "staged": staged})
        exited = run("exit-staged")
        run("verify-old")
        result["cases"].append({"name": "client_exit_rolls_back_and_rebind_reads_old_objects", "passed": True, "exit": exited})
        synced = kill_ready("sync-wait", 4)
        run("verify-new")
        result["cases"].append({"name": "kill_after_sync_ack_recovers_two_objects_and_four_GiB_sparse_tail", "passed": True, "sync": synced})
        rebound = run("sync-rebind")
        run("verify-new")
        result["cases"].append({"name": "unread_sync_reply_survives_exit_and_stale_epoch_and_handle_are_rejected", "passed": True, "rebind": rebound})
        ranges = []
        fd = os.open(image, os.O_RDONLY)
        try:
            require(os.pread(fd, 16 * PAGE, CAPACITY - 16 * PAGE) == bytes(16 * PAGE), "reserved tail modified")
            for label, offset, size in (("metadata", 0, 258 * PAGE),
                                        ("payload", CAPACITY - 1024 * PAGE, rebound["payload_high_water_pages"] * PAGE)):
                name = label + ".bin"
                digest = copy_range(fd, offset, size, output / name)
                ranges.append({"file": name, "offset": offset, "bytes": size, "sha256": digest})
        finally:
            os.close(fd)
        result["snapshot"] = {"capacity": CAPACITY, "ranges": ranges, "omitted_bytes": "zero sparse holes"}
        rebuilt = output / "reconstructed.img"
        create_image(rebuilt)
        fd = os.open(rebuilt, os.O_RDWR)
        try:
            for item in ranges:
                digest = hashlib.sha256()
                position = 0
                with (output / item["file"]).open("rb") as source_file:
                    while data := source_file.read(65536):
                        digest.update(data)
                        require(os.pwrite(fd, data, item["offset"] + position) == len(data), "short restore")
                        position += len(data)
                require(position == item["bytes"] and digest.hexdigest() == item["sha256"], "range mismatch")
            os.fsync(fd)
        finally:
            os.close(fd)
        run("verify-new", rebuilt)
        result["cases"].append({"name": "compact_ranges_reconstruct_wide_service_view", "passed": True})
        result["images"] = {p.name: {"bytes": p.stat().st_size, "allocated_bytes": p.stat().st_blocks * 512}
                            for p in (image, rebuilt)}
        require(all(x["bytes"] == CAPACITY and x["allocated_bytes"] < 16 * 1024**2 for x in result["images"].values()), "sparse geometry lost")
        result["passed"] = True
    finally:
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(output / "results.json")


if __name__ == "__main__":
    main()
