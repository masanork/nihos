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
        result["images"] = {path.name: {"bytes": path.stat().st_size, "allocated_bytes": path.stat().st_blocks * 512}
                            for path in (image, rebuilt)}
        require(all(info["bytes"] == CAPACITY and info["allocated_bytes"] < 256 * 1024**2 for info in result["images"].values()), "image lost sparse allocation")
        result["passed"] = True
    finally:
        (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    print(output / "results.json")


if __name__ == "__main__":
    main()
