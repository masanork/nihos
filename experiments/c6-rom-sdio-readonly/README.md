# Tab5 C6 SDIO ROM read-only experiment

**Build-only, not device-qualified.** This is an ESP-IDF P4 diagnostic, not a
nihos native feature and not an operational recovery method. It requires the
C6 GPIO9 boot strap to be held low externally through a C6 reset. The official
Tab5 schematic routes that signal to the C6 service connector, not to a P4
GPIO; P4 GPIO9 is SDIO D2, not C6 GPIO9. No device was reset or flashed for this
experiment. Do not install or run this fixture without reviewing board wiring,
exclusive P4/C6 ownership, current device identity/security, backup/restore,
and the reset/strap exit sequence.

Espressif's experimental SDIO ROM transport is independent of the C6 Hosted
application, but download-mode entry also requires GPIO8 high, GPIO9 low and
suitable eFuse settings. The entry strap has not been demonstrated through
software alone. The flasher uploads its stub to C6 RAM; it does not need the
C6 Hosted application. Secure download over SDIO is not supported by the
upstream library. `main.c` calls no C6 flash erase or write API; after the
explicit input gate it connects, reads security state, stops for encrypted or
secure-download mode, and compares two reads before reporting the 3 KiB
partition-table hash and 32 KiB boot-region hash. A matching hash alone does
not reveal bootloader configuration without a matching, understood reference.
The fixture has not been audited for every failure cleanup path.

## Reproduce the isolated build

Use ESP-IDF v5.4.4 and a clean checkout of
[esp-serial-flasher](https://github.com/espressif/esp-serial-flasher) at
`ddf3cdd8fa87f3d26b42f1b8ad94bbbb67745f50` (Apache-2.0). Copy this directory
outside the source tree, apply `rom-readonly.patch` to that separate
checkout, and symlink it as `components/esp-serial-flasher` in the copy. The
patch makes `GPIO_NUM_NC` mean that the boot strap is controlled externally;
it avoids driving an unrelated P4 GPIO. It also corrects the loader security
decoder to test odd parity of `flash_crypt_cnt` instead of `key_purposes`.
Run `python3 check-security-parity.py PATH_TO_PATCHED_CHECKOUT` to exercise the
actual decoder across all 256 counter values and four key-purpose patterns.
The same test fails against the uncorrected pinned source. Then build with IDF component manager
disabled using `IDF_COMPONENT_MANAGER=0 idf.py build`. Do not use generated
flash commands as an authorization to install it.

The 2026-11-01 local build produced a 295,408-byte P4 app with SHA-256
`e4a41bb2bd61bea8bac6a03ec43d1702aaeab1dec03dd322c7173017a112c7c7`.
Binary identity may vary with build path and tools. This result is compilation
only; no C6 bootloader, partition, eFuse or flash bytes were read.

References: [M5Stack Tab5 pin map and schematic](https://docs.m5stack.com/en/core/Tab5),
[M5Stack C6 service connector](https://docs.m5stack.com/en/guide/tab5/c6_wifi_restore),
[ESP32-C6 boot mode](https://docs.espressif.com/projects/esptool/en/latest/esp32c6/advanced-topics/boot-mode-selection.html),
[Espressif SDIO flasher](https://github.com/espressif/esp-serial-flasher).

The same local build's final ELF contains `esp_loader_connect` and
`esp_loader_flash_read`, but not symbols named `esp_loader_flash_start`,
`esp_loader_flash_write`, `esp_loader_flash_erase`, or an eFuse burn/write API.
This symbol inspection and source review do not replace runtime verification.

For comparison only, the M5Stack UserDemo factory image
`ESP32C6-WiFi-SDIO-Interface-V1.4.1-96bea3a_0x0.bin` had SHA-256
`1173bf86ab86c8dbd3f9863d10b15c2e46f57000b2b77c803e2b79bd0a3fa38e`.
Its first 32 KiB hash was
`ac0dd1c1df78ec2cc17ef8cee73ab748a4085df87175a48a9ab962895e48145e`, and
its partition table at `0x8000`, over 3 KiB, had SHA-256
`0241fa0d2e573dee86756e39fb4181e61ff7218087619cab565b602df55954d6`.
These are published-image comparisons, not a readback from this Tab5.
