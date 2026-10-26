#!/usr/bin/env python3
"""Build and inventory the pinned external C6 ESP-AT tree; never flash a device.

Install upstream SDK tools/Python requirements in a separate IDF_TOOLS_PATH
first. --source must contain the exact ESP-AT and esp-idf commits below.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

AT_REVISION = "7c092f9aee793d6dbfae31e7585637baa14fb4ce"
IDF_REVISION = "8ad0d3d8f2faab752635bee36070313c47c07a13"
REQUIRED = (
    "CONFIG_IDF_TARGET_ESP32C6", "CONFIG_AT_BASE_ON_SDIO",
    "CONFIG_AT_ENABLE", "CONFIG_AT_WIFI_COMMAND_SUPPORT",
    "CONFIG_AT_NET_COMMAND_SUPPORT", "CONFIG_AT_BLE_COMMAND_SUPPORT",
    "CONFIG_BT_ENABLED", "CONFIG_BT_NIMBLE_ENABLED",
    "CONFIG_ESP_COEX_SW_COEXIST_ENABLE",
)


def output(args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def sdk_changes(path):
    paths = ["."] + [line.split()[1] for line in output(["git", "-C", str(path), "submodule", "status", "--recursive"]).splitlines()]
    return {name: diff for name in paths if (diff := output(["git", "-C", str(path / name), "diff", "--binary", "HEAD"]))}


def verify_source(path, revision, previous_changes=None):
    if output(["git", "-C", str(path), "rev-parse", "HEAD"]) != revision:
        raise ValueError(f"unexpected source revision: {path}")
    if output(["git", "-C", str(path), "status", "--porcelain", "--untracked-files=no"]) and (
        previous_changes is None or sdk_changes(path) != previous_changes
    ):
        raise ValueError(f"tracked source modifications: {path}")


def read_config(path):
    result = {}
    for line in path.read_text().splitlines():
        if line.startswith("CONFIG_") and "=" in line:
            key, value = line.split("=", 1)
            result[key] = value
    return result


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--tools", type=Path, required=True, help="isolated IDF_TOOLS_PATH")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    source = args.source.resolve()
    sdk = source / "esp-idf"
    tools = args.tools.resolve()
    dest = (args.output or root / "build/c6-at").resolve()
    if any(any(c.isspace() for c in str(p)) for p in (root, source, tools, dest)):
        raise ValueError("upstream ESP-AT requires paths without whitespace")
    verify_source(source, AT_REVISION)
    state = dest / "sdk-upstream-patches.json"
    previous_changes = json.loads(state.read_text()) if state.exists() else None
    verify_source(sdk, IDF_REVISION, previous_changes)
    # A dedicated checkout is required: upstream generation reads this fixed path.
    module = source / "build/module_info.json"
    module.parent.mkdir(exist_ok=True)
    selection = {"platform": "PLATFORM_ESP32C6", "module": "ESP32C6-4MB", "silence": 0}
    if module.exists() and any(json.loads(module.read_text()).get(k) != v for k, v in selection.items()):
        raise ValueError("existing upstream module selection differs; use a dedicated checkout")
    module.write_text(json.dumps(selection, indent=2) + "\n")
    dest.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    # Do not inherit a P4 virtual environment or SDK selection.
    for name in ("IDF_PYTHON_ENV_PATH", "VIRTUAL_ENV", "PYTHONHOME", "PYTHONPATH"):
        env.pop(name, None)
    env.update(IDF_PATH=str(sdk), IDF_TOOLS_PATH=str(tools), PYTHONNOUSERSITE="1")
    exports = output([sys.executable, str(sdk / "tools/idf_tools.py"), "export", "--format=key-value"], env=env)
    for line in exports.splitlines():
        key, value = line.split("=", 1)
        env[key] = value.replace("${PATH}", env["PATH"]).replace("$PATH", env["PATH"])
    python = Path(env["IDF_PYTHON_ENV_PATH"]) / "bin/python"
    env.update(
        AT_EXT_MODULE_CFG=str(root / "ports/esp32c6-at"),
        ESP_AT_PROJECT_PLATFORM="PLATFORM_ESP32C6", ESP_AT_MODULE_NAME="ESP32C6-4MB",
        ESP_AT_PROJECT_PATH=str(source), ESP_AT_PROJECT_BRANCH="release/v4.1.0.0", SILENCE="0",
    )
    # Several upstream generators hard-code project/sdkconfig and project/build,
    # including factory-image generation. Build in this dedicated checkout.
    firmware = source / "build"
    sdkconfig = source / "sdkconfig"
    with (dest / "build.log").open("w") as log:
        try:
            subprocess.run([
                str(python), str(sdk / "tools/idf.py"), "-B", str(firmware),
                "-D", f"SDKCONFIG={sdkconfig}", "-D", "IDF_TARGET=esp32c6", "reconfigure", "build",
            ], cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
        finally:
            # Pinned ESP-AT applies its own SDK patches during configuration.
            # Permit a subsequent build only if those exact changes remain.
            state.write_text(json.dumps(sdk_changes(sdk), indent=2) + "\n")
    config = read_config(sdkconfig)
    if any(config.get(key) != "y" for key in REQUIRED) or config.get("CONFIG_AT_BASE_ON_UART") == "y":
        raise ValueError("resolved config does not enable the required SDIO/Wi-Fi/BLE profile")
    if config.get("CONFIG_AT_SDIO_BLOCK_SIZE") != "512":
        raise ValueError("resolved SDIO block size differs")
    # Upstream uses copied patch files as markers, even if the underlying SDK
    # changes were subsequently reverted. Check the actual patched content.
    patch_inputs = {}
    for name in ("support_ext_partition.patch", "dhcp_option_len.patch"):
        patch = source / "patches" / name
        subprocess.run(["git", "apply", "--reverse", "--check", str(patch)], cwd=sdk, check=True)
        patch_inputs[name] = digest(patch)
    # Retain SDK/component selection and offline-generated images. No flash,
    # read-flash, monitor or other serial operation is invoked.
    flash_args = json.loads((firmware / "flasher_args.json").read_text())
    originals = sorted({firmware / name for name in flash_args["flash_files"].values()} | set((firmware / "factory").glob("*.bin")))
    if not (firmware / "esp-at.bin").exists():
        raise ValueError("C6 app image is absent")
    files = []
    for path in originals:
        copy = dest / "firmware" / path.relative_to(firmware)
        copy.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, copy)
        files.append(copy)
    for name in ("esp-at.elf", "esp-at.map", "flasher_args.json", "flash_args", "flash_project_args"):
        path = firmware / name
        if path.exists():
            shutil.copyfile(path, dest / "firmware" / name)
    inputs = {}
    for name, path in (
        ("overlay", root / "ports/esp32c6-at/sdkconfig.defaults"),
        ("sdkconfig", sdkconfig), ("module", module),
        ("components", source / "dependencies.lock"),
        ("submodules", sdk / ".gitmodules"),
        ("sdk-patches", state),
        ("build-script", Path(__file__).resolve()),
        ("idf-tools", sdk / "tools/tools.json"),
    ):
        if path.exists():
            copy = dest / (name + path.suffix)
            if path != copy:
                shutil.copyfile(path, copy)
            inputs[name] = {"file": copy.name, "sha256": digest(copy)}
    submodules = output(["git", "-C", str(sdk), "submodule", "status", "--recursive"])
    if any(line.startswith(("-", "+", "U")) for line in submodules.splitlines()):
        raise ValueError("SDK submodules are missing or differ from the pin")
    (dest / "sdk-submodules.txt").write_text(submodules + "\n")
    (dest / "python-packages.txt").write_text(output([str(python), "-m", "pip", "freeze"], env=env) + "\n")
    receipt = {
        "schema": 1, "status": "passed", "scope": "C6 compile only; no flash or execution",
        "esp_at": AT_REVISION, "esp_idf": IDF_REVISION,
        "nihos": output(["git", "-C", str(root), "rev-parse", "HEAD"]),
        "nihos_dirty": bool(output(["git", "-C", str(root), "status", "--porcelain"])),
        "inputs": inputs,
        "required_upstream_patches": patch_inputs,
        "flash_files": flash_args["flash_files"],
        "tools": {
            "compiler": output(["riscv32-esp-elf-gcc", "--version"], env=env).splitlines()[0],
            "python": output([str(python), "--version"], env=env),
            "cmake": output(["cmake", "--version"], env=env).splitlines()[0],
            "ninja": output(["ninja", "--version"], env=env),
            "python_packages_sha256": digest(dest / "python-packages.txt"),
        },
        "binaries": [{"file": str(p.relative_to(dest)), "bytes": p.stat().st_size, "sha256": digest(p)} for p in files],
    }
    (dest / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"C6 SDIO/Wi-Fi/NimBLE build passed; receipt: {dest / 'receipt.json'}")


if __name__ == "__main__":
    main()
