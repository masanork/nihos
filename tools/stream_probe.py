#!/usr/bin/env python3
"""Fixed-buffer large-object streaming, cancellation and process-lifetime checks."""
import hashlib
import json
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys

CAPACITY = 16 * 1024**3
PAGE = 4096
PAYLOAD_START = CAPACITY - 32768 * PAGE


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def create_image(path):
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.ftruncate(fd, CAPACITY)
        require(os.pwrite(fd, b"\xff" * (2 * PAGE), 0) == 2 * PAGE, "short root initialization")
        os.fsync(fd)
    finally:
        os.close(fd)
    fd = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def copy_range(source_fd, offset, length, target):
    digest = hashlib.sha256()
    position = 0
    with target.open("xb") as output:
        while position < length:
            data = os.pread(source_fd, min(65536, length - position), offset + position)
            require(data, "short snapshot read")
            output.write(data)
            digest.update(data)
            position += len(data)
        output.flush()
        os.fsync(output.fileno())
    return digest.hexdigest()


def main():
    source, output = map(Path, sys.argv[1:])
    output = output.resolve()
    require(output.is_dir() and not any(output.iterdir()), "output must be new and empty")
    binary = output / "stream-probe"
    shutil.copy2(source, binary)
    image = output / "volume.img"
    result = {"schema": 1, "evidence": "host-fixed-buffer-streaming", "physical_power_cuts": 0,
              "capacity": CAPACITY, "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
              "commands": [], "cases": [], "passed": False}

    def run(command, path=image):
        process = subprocess.run([str(binary), command, str(path)], capture_output=True, text=True, timeout=180)
        result["commands"].append({"command": command, "image": path.name, "exit_code": process.returncode,
                                    "stdout": process.stdout, "stderr": process.stderr})
        require(process.returncode == 0, f"{command} failed: {process.stderr}")
        data = json.loads(process.stdout)
        require(data["object_bytes"] > 32 * 1024**2 and data["input_buffer_bytes"] == PAGE, "not a fixed-buffer large-object probe")
        require(data["state_bytes"] <= 640 * 1024, "store state exceeds profile")
        return data

    def kill_ready(command, generation):
        process = subprocess.Popen([str(binary), command, str(image)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                require(selector.select(timeout=180), f"{command} readiness timeout")
            line = process.stdout.readline()
            ready = json.loads(line)
            require(ready["generation"] == generation and ready["phase"] == command, "bad readiness state")
            process.kill()  # Only the child created above.
            stdout, stderr = process.communicate(timeout=30)
            result["commands"].append({"command": command, "pid": process.pid, "exit_code": process.returncode,
                                        "readiness": ready, "stdout": stdout, "stderr": stderr})
            require(process.returncode == -9, "owned probe was not SIGKILLed")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=30)

    try:
        create_image(image)
        run("format")
        seeded = run("seed")
        run("verify-old")
        result["cases"].append({"name": "33MiB_object_with_4KiB_input_reopens", "passed": True, "seed": seeded})
        run("cancel")
        run("verify-old")
        result["cases"].append({"name": "cancel_after_1MiB_keeps_old_object", "passed": True})
        kill_ready("stage-wait", 2)
        run("verify-old")
        result["cases"].append({"name": "kill_during_stream_keeps_old_generation", "passed": True})
        kill_ready("finish-wait", 2)
        run("verify-old")
        result["cases"].append({"name": "kill_after_finish_before_commit_keeps_old_generation", "passed": True})
        kill_ready("patch-wait", 3)
        changed = run("verify-new")
        result["cases"].append({"name": "patch_crosses_checksum_table_boundary_and_survives_kill_after_ack", "passed": True, "reopened": changed})
        extent_bytes = (seeded["data_pages"] + seeded["checksum_pages"]) * PAGE
        ranges = []
        fd = os.open(image, os.O_RDONLY)
        try:
            require(os.pread(fd, 16 * PAGE, CAPACITY - 16 * PAGE) == bytes(16 * PAGE), "reserved tail modified")
            for label, offset, length in (("metadata", 0, 258 * PAGE), ("payload", PAYLOAD_START, 2 * extent_bytes)):
                name = label + ".bin"
                digest = copy_range(fd, offset, length, output / name)
                ranges.append({"file": name, "offset": offset, "bytes": length, "sha256": digest})
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
                        require(os.pwrite(fd, data, item["offset"] + position) == len(data), "short range restore")
                        position += len(data)
                require(position == item["bytes"] and digest.hexdigest() == item["sha256"], "range restore mismatch")
            os.fsync(fd)
        finally:
            os.close(fd)
        run("verify-new", rebuilt)
        result["cases"].append({"name": "compact_range_reconstruction_reopens_patched_object", "passed": True})
        promoted = run("promote-map")
        run("verify-map-old")
        require(promoted["writes"] == promoted["map_metadata_pages"] + 2, "promotion copied payload")
        result["cases"].append({"name": "map_promotion_shares_existing_33MiB_payload", "passed": True, "promotion": promoted})
        kill_ready("mapped-patch-wait", 5)
        mapped = run("verify-map-new")
        root_only = run("collect-map")
        run("verify-map-new")
        mapped_patch = next(item["readiness"] for item in result["commands"] if item["command"] == "mapped-patch-wait")
        legacy_patch = next(item["readiness"] for item in result["commands"] if item["command"] == "patch-wait")
        require(mapped_patch["writes"] < legacy_patch["writes"], "extent map did not reduce patch writes")
        result["cases"].append({"name": "mapped_patch_changes_two_pages_and_survives_ack_kill", "passed": True,
                                 "patch": mapped_patch, "reopened": mapped, "collected": root_only,
                                 "legacy_write_bytes": legacy_patch["writes"] * PAGE,
                                 "mapped_write_bytes": mapped_patch["writes"] * PAGE})
        fd = os.open(image, os.O_RDONLY)
        try:
            # The previous payload range is shared unchanged. Save only the
            # newly appended map/data pages, not another large payload copy.
            for item in ranges:
                if item["file"] != "payload.bin":
                    continue
                digest = hashlib.sha256()
                position = 0
                while position < item["bytes"]:
                    data = os.pread(fd, min(65536, item["bytes"] - position), item["offset"] + position)
                    require(data, "short shared range read")
                    digest.update(data)
                    position += len(data)
                require(digest.hexdigest() == item["sha256"], "shared payload was rewritten")
            metadata_hash = copy_range(fd, 0, 258 * PAGE, output / "mapped-metadata.bin")
            extension_offset = PAYLOAD_START + 2 * extent_bytes
            extension_bytes = root_only["payload_high_water_pages"] * PAGE - 2 * extent_bytes
            require(extension_bytes > 0, "missing map extension")
            extension_hash = copy_range(fd, extension_offset, extension_bytes, output / "map-pages.bin")
        finally:
            os.close(fd)
        mapped_ranges = [{"file": "mapped-metadata.bin", "offset": 0, "bytes": 258 * PAGE, "sha256": metadata_hash},
                         next(item for item in ranges if item["file"] == "payload.bin"),
                         {"file": "map-pages.bin", "offset": extension_offset, "bytes": extension_bytes, "sha256": extension_hash}]
        result["mapped_snapshot"] = {"capacity": CAPACITY, "ranges": mapped_ranges, "omitted_bytes": "zero sparse holes"}
        mapped_image = output / "mapped-reconstructed.img"
        create_image(mapped_image)
        fd = os.open(mapped_image, os.O_RDWR)
        try:
            for item in mapped_ranges:
                position = 0
                with (output / item["file"]).open("rb") as source_file:
                    while data := source_file.read(65536):
                        require(os.pwrite(fd, data, item["offset"] + position) == len(data), "short mapped restore")
                        position += len(data)
                require(position == item["bytes"], "mapped range length mismatch")
            os.fsync(fd)
        finally:
            os.close(fd)
        run("verify-map-new", mapped_image)
        result["cases"].append({"name": "mapped_range_snapshot_reuses_unchanged_payload_file", "passed": True})
        resized = run("resize-cycle")
        require(resized["writes"] == 11, "resize rewrote more than two boundary paths and root retirement")
        run("verify-resized")
        result["cases"].append({"name": "truncate_regrow_zero_tail_and_pinned_old_reader", "passed": True,
                                 "resize": resized, "scratch_bytes": 16384, "shrink_payload_pages": 3,
                                 "grow_payload_pages": 3, "zero_after": 33 * 1024**2 + 17 - PAGE - 13})
        # Reclamation can reuse old physical pages. Preserve the earlier
        # snapshots and capture this generation as independent ranges.
        resized_ranges = []
        fd = os.open(image, os.O_RDONLY)
        try:
            require(os.pread(fd, 16 * PAGE, CAPACITY - 16 * PAGE) == bytes(16 * PAGE), "reserved tail modified")
            for name, offset, size in (("resized-metadata.bin", 0, 258 * PAGE),
                                       ("resized-payload.bin", PAYLOAD_START, resized["payload_high_water_pages"] * PAGE)):
                digest = copy_range(fd, offset, size, output / name)
                resized_ranges.append({"file": name, "offset": offset, "bytes": size, "sha256": digest})
        finally:
            os.close(fd)
        result["resized_snapshot"] = {"capacity": CAPACITY, "ranges": resized_ranges, "omitted_bytes": "zero sparse holes"}
        resized_image = output / "resized-reconstructed.img"
        create_image(resized_image)
        fd = os.open(resized_image, os.O_RDWR)
        try:
            for item in resized_ranges:
                position = 0
                with (output / item["file"]).open("rb") as source_file:
                    while data := source_file.read(65536):
                        require(os.pwrite(fd, data, item["offset"] + position) == len(data), "short resized restore")
                        position += len(data)
                require(position == item["bytes"], "resized range length mismatch")
            os.fsync(fd)
        finally:
            os.close(fd)
        run("verify-resized", resized_image)
        result["cases"].append({"name": "resized_range_snapshot_reopens_without_resurrecting_tail", "passed": True})
        baseline = run("batch-single-reference", resized_image)
        run("verify-batch", resized_image)
        require(baseline["writes"] == 65, "unexpected unbatched reference cost")
        result["cases"].append({"name": "sixteen_separate_page_updates_reference", "passed": True, "reference": baseline})
        kill_ready("batch-stage-wait", 9)
        run("verify-resized")
        result["cases"].append({"name": "kill_staged_batch_keeps_entire_old_file", "passed": True})
        kill_ready("batch-wait", 10)
        run("verify-batch")
        collected_batch = run("collect-batch")
        run("verify-batch")
        batch = next(item["readiness"] for item in result["commands"] if item["command"] == "batch-wait")
        require(batch["map_scratch_bytes"] == 16384 and batch["batch_descriptor_bytes"] == 384, "batch workspace exceeded expected host layout")
        require(batch["writes"] == 20, "batch failed to share map and object-leaf writes")
        result["cases"].append({"name": "sixteen_page_batch_survives_ack_kill_and_gc", "passed": True,
                                 "batch": batch, "reference_write_bytes": baseline["writes"] * PAGE,
                                 "batch_write_bytes": batch["writes"] * PAGE, "scratch_bytes": 16384,
                                 "input_bytes": 16, "host_patch_descriptors_bytes": batch["batch_descriptor_bytes"]})
        batch_ranges = []
        fd = os.open(image, os.O_RDONLY)
        try:
            for item in resized_ranges:
                if item["file"] == "resized-payload.bin":
                    digest = hashlib.sha256()
                    position = 0
                    while position < item["bytes"]:
                        data = os.pread(fd, min(65536, item["bytes"] - position), item["offset"] + position)
                        require(data, "short shared resized range")
                        digest.update(data)
                        position += len(data)
                    require(digest.hexdigest() == item["sha256"], "batch rewrote shared previous payload")
            for name, offset, size in (("batch-metadata.bin", 0, 258 * PAGE),
                                       ("batch-pages.bin", PAYLOAD_START + resized["payload_high_water_pages"] * PAGE,
                                        (collected_batch["payload_high_water_pages"] - resized["payload_high_water_pages"]) * PAGE)):
                require(size > 0, "missing batch snapshot range")
                digest = copy_range(fd, offset, size, output / name)
                batch_ranges.append({"file": name, "offset": offset, "bytes": size, "sha256": digest})
        finally:
            os.close(fd)
        batch_ranges.append(next(item for item in resized_ranges if item["file"] == "resized-payload.bin"))
        result["batch_snapshot"] = {"capacity": CAPACITY, "ranges": batch_ranges, "omitted_bytes": "zero sparse holes"}
        batch_image = output / "batch-reconstructed.img"
        create_image(batch_image)
        fd = os.open(batch_image, os.O_RDWR)
        try:
            for item in batch_ranges:
                position = 0
                with (output / item["file"]).open("rb") as source_file:
                    while data := source_file.read(65536):
                        require(os.pwrite(fd, data, item["offset"] + position) == len(data), "short batch restore")
                        position += len(data)
                require(position == item["bytes"], "batch range length mismatch")
            os.fsync(fd)
        finally:
            os.close(fd)
        run("verify-batch", batch_image)
        result["cases"].append({"name": "batch_snapshot_reuses_previous_payload_and_reopens", "passed": True})
        result["images"] = {path.name: {"bytes": path.stat().st_size, "allocated_bytes": path.stat().st_blocks * 512}
                            for path in (image, rebuilt, mapped_image, resized_image, batch_image)}
        require(all(info["bytes"] == CAPACITY and info["allocated_bytes"] < 256 * 1024**2 for info in result["images"].values()), "image lost sparse allocation")
        result["passed"] = True
    finally:
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(output / "results.json")


if __name__ == "__main__":
    main()
