# ESP32-C6 SDIO network firmware experiment

This directory is an external ESP-AT configuration overlay, not a P4 project.
`tools/build_c6_at.py` builds a separate, pinned upstream checkout and retains
its images, resolved config, component lock, SDK patches and hashes. It never
opens a serial port or flashes a device. The built-in upstream image-generation
steps do run esptool in offline mode.

## Prepare a dedicated upstream checkout and tool environment

The following commands were exercised on macOS ARM64 with Python 3.12. Git,
CMake and Ninja must already be installed. Keep paths free of whitespace.
Run from the nihos repository. The source and tools stay in ignored `.tools`.

```sh
task_at="$PWD/.tools/esp-at-c6"
task_tools="$PWD/.tools/c6-idf"
git clone --depth 1 --branch v4.1.1.0 https://github.com/espressif/esp-at.git "$task_at"
git init "$task_at/esp-idf"
git -C "$task_at/esp-idf" remote add origin https://github.com/espressif/esp-idf.git
git -C "$task_at/esp-idf" fetch --depth 1 origin 8ad0d3d8f2faab752635bee36070313c47c07a13
git -C "$task_at/esp-idf" checkout --detach FETCH_HEAD
git -C "$task_at/esp-idf" submodule update --init --recursive --depth 1 --jobs 8
export IDF_TOOLS_PATH="$task_tools"
python3.12 "$task_at/esp-idf/tools/idf_tools.py" install --targets esp32c6
python3.12 "$task_at/esp-idf/tools/idf_tools.py" install-python-env
"$task_tools/python_env/idf5.4_py3.12_env/bin/python" -m pip install -r "$task_at/requirements.txt"
python3.12 tools/build_c6_at.py --source "$task_at" --tools "$task_tools"
```

Use the upstream ESP-AT commit
`7c092f9aee793d6dbfae31e7585637baa14fb4ce`, SDK base
`8ad0d3d8f2faab752635bee36070313c47c07a13`, and the submodules at that
SDK revision. The script refuses a different source revision or unexplained
tracked modifications. ESP-AT applies its own SDK patches during configure;
the first build must start with a clean SDK. Their resulting changes are
recorded in `sdk-upstream-patches.json`; subsequent invocations accept only
the recorded state. Two required patches are also checked against the actual
SDK content using `git apply --reverse --check` after every build.

Upstream generators require `<source>/sdkconfig` and `<source>/build`, so
the checkout must be dedicated to this experiment. An existing module
selection for another target is rejected. Source preparation and tool
installation are explicit; the builder does not reset an existing checkout.
The output defaults to `build/c6-at` in nihos; `--output` can select another
artifact directory. Reuse that output for subsequent builds so its recorded
SDK patch state remains available. If settings change, use a fresh dedicated
checkout/output rather than relying on old sdkconfig values being replaced.

## Artifacts and interpretation

- `receipt.json`: exact source pins, configuration/tool recipe hashes,
  binary lengths/hashes and upstream flash file offsets.
- `sdkconfig`, `overlay.defaults`, `module.json`, `components.lock`,
  `submodules`, `sdk-submodules.txt`, `sdk-patches.json`, `build-script.py`:
  retained inputs and dependency state.
- `firmware/`: application, bootloader, partition data, upstream factory
  images, ELF/map and upstream flash metadata.
- `build.log`: compiler output. Its printed flash commands were not executed.

The first profile enables SDIO, Wi-Fi, TCP/IP, NimBLE and coexistence together.
MQTT, HTTP, OTA and BluFi AT command registration are disabled to keep this
experiment focused. TCP sockets can still carry HTTP or TLS application data.
The controller currently exposes TCP and BLE client operations; TLS trust
configuration and application integration remain separate work.

The upstream C6 module profile assumes 4 MiB flash. This build is not evidence
for the installed module's flash size, boot, SDIO compatibility, memory headroom,
radio coexistence or network behavior. Identify and back up the actual C6
before any write; P4 OTA recovery cannot restore a changed C6 image. Follow
the [runbook](../../docs/planning/c6-network-offload.md) for physical gates.
