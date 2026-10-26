# Native display preparation: host/build checkpoint

Date: 2026-10-26. Scope: **host and build only; no device flash/reset or panel result**.

Based on the qualified native-memory/SD snapshot `fbbce97` and boot-lettering commit `9576551`.
The exact implementation file hashes and image identities are in the [JSON receipt](2026-10-26-native-display-preparation.json).

## Results

- Zig Debug and ReleaseSafe: 170/170 tests each.
- Native image/log/stack Python suites: 106 tests passed.
- Formatting, ZLint (zero warnings), ShellCheck and diff whitespace checks passed.
- The existing architecture gate passed its 20 image negative tests and six default device/emulator native ELF audits.
- Display-only and display+SDMMC integer images pass the unchanged full native image/loader audit.
- The compressed font masks occur exactly once inside each image's existing non-executable, non-writable Flash table span.
- Host replay still uses the real Zig renderer. The expected CPU image FNV-1a for colour value 255 with status DISPLAY is `0xa3112444`.

| Image | Image bytes | Primary static SRAM | Owner SRAM heap | Read-only Flash span |
| --- | ---: | ---: | ---: | ---: |
| display only | 116,928 | 85,120 | 78,720 | 31,049 |
| display + SDMMC | 124,880 | 93,120 | 70,720 | 31,573 |

Both images remain integer-only and RTOS-free. The build checks do not establish power voltage, panel identity on this device, PHY lock, pixel delivery, tearing, or scheduling/storage coexistence.

## Not yet qualified

The opt-in runtime records preparation only: board power, panel identification, CPU framebuffer/cache handoff, then PHY lock and stopped-lane status. The PHY is shut down afterwards. Vendor DCS initialization, DPI bridge/GDMA refresh and backlight-on are still absent, so `scanout=0 backlight=0` is intentional.

The framebuffer reservation is 1,900,544 bytes at `0x48030000`, and external owner heaps begin at `0x48200000` only when the option is enabled. Host tests verify real MMU page mappings and non-overlap on 4–64 MiB capacities.

The physical Tab5 was reserved for parallel filesystem qualification. No serial port was opened and no firmware or SD content was changed by this display task.

See [native display bring-up](../native-display.md) for the report format, build flags and next physical gate.
