#!/usr/bin/env python3
"""Separate-process checkpoint experiment over a sparsely allocated 16 GiB file."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

CAPACITY = 16 * 1024**3
PAGE = 4096
METADATA_BYTES = 258 * PAGE
PAYLOAD_START = CAPACITY - 64 * PAGE


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sync_directory(directory):
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def create_sparse(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.ftruncate(fd, CAPACITY)
        require(os.pwrite(fd, b"\xff" * (2 * PAGE), 0) == 2 * PAGE, "short root initialization")
        os.fsync(fd)
    finally:
        os.close(fd)
    sync_directory(path.parent)


def capture(path, output, name):
    ranges = []
    fd = os.open(path, os.O_RDONLY)
    try:
        for label, offset, length in (("metadata", 0, METADATA_BYTES), ("payload", PAYLOAD_START, CAPACITY - PAYLOAD_START)):
            data = os.pread(fd, length, offset)
            require(len(data) == length, "short snapshot read")
            filename = f"{name}-{label}.bin"
            (output / filename).write_bytes(data)
            ranges.append({"offset": offset, "bytes": length, "file": filename, "sha256": hashlib.sha256(data).hexdigest()})
    finally:
        os.close(fd)
    return {"capacity": CAPACITY, "omitted_bytes": "zero-filled sparse holes", "ranges": ranges}


def restore(snapshot, output, path):
    create_sparse(path)
    fd = os.open(path, os.O_RDWR)
    try:
        for item in snapshot["ranges"]:
            data = (output / item["file"]).read_bytes()
            require(hashlib.sha256(data).hexdigest() == item["sha256"], "snapshot hash mismatch")
            require(os.pwrite(fd, data, item["offset"]) == len(data), "short snapshot restore")
        os.fsync(fd)
    finally:
        os.close(fd)


def main():
    source, output = map(Path, sys.argv[1:])
    output = output.resolve()
    require(output.is_dir() and not any(output.iterdir()), "output must be a new empty directory")
    binary = output / "checkpoint-probe"
    shutil.copy2(source, binary)
    image = output / "volume.img"
    results = {"schema": 1, "evidence": "host-sparse-file-checkpoint", "physical_power_cuts": 0,
               "capacity": CAPACITY, "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
               "commands": [], "cases": [], "snapshots": {}, "passed": False}

    def run(command, path=image, failure=None):
        completed = subprocess.run([str(binary), command, str(path)], capture_output=True, text=True, timeout=30)
        results["commands"].append({"command": command, "image": path.name, "exit_code": completed.returncode,
                                    "stdout": completed.stdout, "stderr": completed.stderr})
        if failure:
            require(completed.returncode != 0 and failure in completed.stderr, f"{command}: expected {failure}")
            return None
        require(completed.returncode == 0, f"{command} failed: {completed.stderr}")
        data = json.loads(completed.stdout)
        require(data["state_bytes"] <= 32 * 1024, "descriptor budget exceeded")
        require(data["mount_bytes"] <= data["mount_limit_bytes"] == 258 * PAGE, "mount budget exceeded")
        require(data["tail_replay_bytes"] == 0, "unexpected replay")
        return data

    try:
        create_sparse(image)
        run("format")
        run("seed")
        old = run("verify-old")
        require(old["generation"] == 2 and old["mount_bytes"] == 5 * PAGE, "old checkpoint geometry")
        run("update")
        new = run("verify-new")
        require(new["generation"] == 3 and new["mount_bytes"] == 8 * PAGE, "new checkpoint geometry")
        require(new["payload_first_byte"] > 2**32, "did not exercise a 64-bit file offset")
        results["cases"].append({"name": "separate_process_reopen_above_4GiB", "passed": True, "old": old, "new": new})
        results["snapshots"]["generation3"] = capture(image, output, "generation3")

        one = run("read-one")
        cross = run("read-cross")
        full_scrub = run("verify-full")
        require(one["operation_read_bytes"] == 3 * PAGE, "one-byte read scanned excess data")
        require(cross["operation_read_bytes"] == 4 * PAGE, "crossing read scanned excess data")
        require(full_scrub["operation_read_bytes"] == 20 * PAGE, "full scrub footprint")
        results["cases"].append({"name": "bounded_partial_read_and_explicit_scrub", "passed": True,
                                 "one_byte": one, "crossing": cross, "scrub": full_scrub})

        fd = os.open(image, os.O_RDWR)
        try:
            offset = new["payload_first_byte"] + 17
            original = os.pread(fd, 1, offset)
            require(len(original) == 1, "missing payload byte")
            require(os.pwrite(fd, bytes([original[0] ^ 1]), offset) == 1, "short corruption write")
            os.fsync(fd)
            metadata = run("inspect")
            require(metadata["generation"] == 3, "payload corruption changed metadata mount")
            run("verify-new", failure="Corrupt")
            require(os.pwrite(fd, original, offset) == 1, "short repair write")
            os.fsync(fd)
        finally:
            os.close(fd)
        results["cases"].append({"name": "metadata_only_mount_and_on_demand_payload_integrity", "passed": True})

        fd = os.open(image, os.O_RDWR)
        try:
            offset = new["payload_first_byte"] + 17 * PAGE + 17
            original = os.pread(fd, 1, offset)
            require(len(original) == 1, "missing cold payload byte")
            require(os.pwrite(fd, bytes([original[0] ^ 1]), offset) == 1, "short cold corruption write")
            os.fsync(fd)
            run("read-one")
            run("read-far", failure="Corrupt")
            run("verify-full", failure="Corrupt")
            require(os.pwrite(fd, original, offset) == 1, "short cold repair write")
            os.fsync(fd)
        finally:
            os.close(fd)
        results["cases"].append({"name": "cold_payload_corruption_is_deferred_until_read_or_scrub", "passed": True})

        run("fill-index")
        run("checkpoint")
        full = run("verify-index")
        require(full["mount_bytes"] == 258 * PAGE, "full index did not reach the mount bound")
        results["cases"].append({"name": "both_roots_reference_all_128_leaves", "passed": True, "report": full})
        results["snapshots"]["generation5"] = capture(image, output, "generation5")
        reconstructed = output / "reconstructed.img"
        restore(results["snapshots"]["generation5"], output, reconstructed)
        run("verify-index", reconstructed)
        results["cases"].append({"name": "compact_range_snapshot_reconstruction", "passed": True})
        churn = run("churn-index")
        recycled = run("verify-recycled")
        require(churn["generation"] == 15 and recycled["index_free_pages"] == 128, "index reuse did not survive reopen")
        results["cases"].append({"name": "reader_pin_backpressure_and_640_leaf_mutations_in_256_page_pool", "passed": True,
                                 "churn": churn, "reopened": recycled})
        results["snapshots"]["generation15"] = capture(image, output, "generation15")
        recycled_image = output / "recycled-reconstructed.img"
        restore(results["snapshots"]["generation15"], output, recycled_image)
        run("verify-recycled", recycled_image)
        results["cases"].append({"name": "recycled_index_snapshot_reconstruction", "passed": True})
        fd = os.open(image, os.O_RDONLY)
        try:
            reserve = os.pread(fd, 4 * PAGE, CAPACITY - 4 * PAGE)
        finally:
            os.close(fd)
        require(reserve == bytes(4 * PAGE), "reserved tail was already modified")
        payload_churn = run("churn-payload")
        payload_reopened = run("verify-payload-recycled")
        require(payload_churn["generation"] == 277 and payload_reopened["generation"] == 277, "payload reuse did not survive reopen")
        fd = os.open(image, os.O_RDONLY)
        try:
            reserve_after = os.pread(fd, 4 * PAGE, CAPACITY - 4 * PAGE)
        finally:
            os.close(fd)
        require(reserve_after == reserve, "payload reuse consumed reserved pages")
        results["cases"].append({"name": "64KiB_payload_128_updates_and_two_pins_with_four_page_reserve", "passed": True,
                                 "churn": payload_churn, "reopened": payload_reopened,
                                 "reserved_bytes": 4 * PAGE, "reserve_sha256": hashlib.sha256(reserve).hexdigest()})
        results["snapshots"]["generation277"] = capture(image, output, "generation277")
        payload_image = output / "payload-reconstructed.img"
        restore(results["snapshots"]["generation277"], output, payload_image)
        run("verify-payload-recycled", payload_image)
        results["cases"].append({"name": "recycled_payload_snapshot_reconstruction", "passed": True})
        results["images"] = {}
        for path in (image, reconstructed, recycled_image, payload_image):
            info = path.stat()
            allocated = info.st_blocks * 512
            require(info.st_size == CAPACITY and allocated < 32 * 1024**2, "image lost sparse allocation")
            results["images"][path.name] = {"bytes": info.st_size, "allocated_bytes": allocated}
        results["passed"] = True
    finally:
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(output / "results.json")


if __name__ == "__main__":
    main()
