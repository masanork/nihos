# Native Zig boot on ESP32-P4

This is the first independent native boot fixture. The stock ROM and
second-stage loader hand off to Zig/assembly code in internal SRAM, with no
ESP-IDF application runtime or FreeRTOS link. Both harts keep running under
nihOS-owned trap and timer handling. The existing ESP-IDF display backend is
still a separate implementation.

See [ADR 0018](adr/0018-independent-native-boot.md) for hardware ownership,
boot format constraints and the path to integrating the existing scheduler.

## Build and emulated execution

Install ESP-IDF **v5.4.4** and its ESP32-P4 tools. Set `NIHOS_IDF_PATH` if it
is not already in `IDF_PATH` or `$HOME/esp32/esp-idf-v5.4.4`. Zig 0.17.0 and
ESP-EMU 0.50.0 are checksum-verified by the existing bootstrap scripts.

```sh
sh tools/run-native-smoke.sh
```

This builds only the stock loader and partition table with IDF. Zig links
the native app separately, the image audit runs, and ESP-EMU boots with
`--psram-size 0`. Outputs live under `build/native-emulator/`:

- `nihos-native.elf`, `nihos-native.bin`, `nihos-native-flash.bin`
- `image-audit.json`: sections, ROM boundary, sizes and artifact digests
- `emulator.log`, `smoke-report.json`: 300 rounds and both timer counters

The manual **Native boot** GitHub Actions workflow runs this smoke, builds
the physical profile, and retains the artifacts. It does not flash hardware.

## Physical image

```sh
sh tools/build-native.sh device
```

The image is built for P4 rev1/2 CLIC threshold semantics. The emulator image
uses rev3 semantics; the two headers have disjoint revision ranges. Device
outputs are under `build/native-device/`. The app occupies the factory slot
at `0x10000`; the merged image includes loader at `0x2000` and partition table
at `0x8000` and is written at `0x0`.

Physical qualification is pending: the shared Tab5 was occupied by another
development operation during this milestone. Do not interpret a successful
device-profile build as a physical boot result. In this fixture the console
is the output; display, touch and external RAM are not initialized.

The 300-round smoke has six validator regression tests, including frozen
hart/timer counters, incomplete execution, a reboot and a later failure:

```sh
python3 tools/native_checks_test.py
```
