# Native Tab5 display bring-up

This is an opt-in **preparation probe**, not a working native display backend.
It runs under the independent SRAM application, without ESP-IDF application
code or FreeRTOS, before CPU1 release. The native default remains unchanged.
The BSP/LL sources used as references are recorded in
[board provenance](../src/board/tab5/provenance.toml).

## Implemented boundary

1. Force GPIO22 backlight low, and acquire GPIO31/32 as boot-only open-drain
   I2C pins. Clock stretching, idle-bus checking, address/data NACK distinction,
   arbitration loss, repeated START and final read NACK are bounded. A busy
   bus is rejected without recovery pulses or peripheral-wide resets.
2. Verify the PI4IOE5V6408 identity and update only LCD_EN/TOUCH_EN bits.
   Read-modify-write and readback preserve all unrelated camera/speaker/power
   bits. The shared expander is not reset. Power-up waits 500 ms as in BSP 1.3.2.
3. Select ST7121 from touch firmware 1, ST7123 from firmware 3, or ILI9881C
   from a GT911 product ID. Only an address NACK at 0x55 permits the GT911
   fallback; unknown firmware, command NACK, or a broken bus cannot select a
   different panel. The panel remains uninitialized at the DCS level.
4. Draw the existing boot inscription into reserved PSRAM and write back L2.
   The FNV-1a checksum is CPU image evidence, not DMA or panel evidence.
   Immutable lettering is placed in the existing read-only second mapped
   Flash span, avoiding a 28 KiB charge to the owner-local SRAM heaps.
5. Configure only VO3 for the MIPI PHY's 2.5 V reference setting, using the
   vendor integer eFuse-calibration calculation. Configure the dedicated
   two-lane DSI PHY for 1 Gbit/s from the retained 20 MHz source on rev1/2.
   Poll PLL lock and both stopped lanes with a 50 ms deadline. Register/lock
   evidence does not measure voltage or qualify link timing.
6. Shut down the PHY and its dedicated clocks/VO3 again. Release both I2C
   outputs and stop the temporarily borrowed CPU0 timer. The caller restores
   its scheduler timer configuration before releasing CPU1.

No DCS vendor command table, DPI video timing, bridge/GDMA scanout, DMA refresh
handler, or backlight-on path is implemented. **Even a successful preparation
probe leaves the screen dark.** The report always has `scanout=0 backlight=0`.
Do not interpret `status=1` as visible boot graphics or native display readiness.

## PSRAM ownership

The existing first three 64 KiB virtual pages are nonidentity mapping tests.
The framebuffer is instead reserved at **0x48030000** for 1,843,200 bytes,
inside a page-aligned **1,900,544-byte** reservation. The two external owner
heaps begin at **0x48200000**, splitting the remaining capacity through the
existing allocator setup. The opt-in probe does not hand out this reservation
to tasks, including when the probe fails before allocator registration.

Every reserved page is identity-mapped on the supported 4/8/16/32/64 MiB
capacities. The PSRAM tail is deliberately not used because the current mapper
swaps it with physical page 2. Tests check actual `physicalPage()` results,
not just address arithmetic. The default, without this option, reserves no
framebuffer and retains the original owner heap range.

There are no SD/block/filesystem calls in the display modules. VO2/PSRAM and
VO4/SD settings and SD pins are not written by the display pad/PHY shim.
SDMMC compatibility below is a compile/link result, not a concurrent bandwidth
or physical coexistence result.

## Build and report

```sh
NIHOS_NATIVE_DISPLAY=1 sh tools/build-native.sh device integer
# Compile/link coexistence, without running or writing an SD card:
NIHOS_NATIVE_DISPLAY=1 NIHOS_NATIVE_SDMMC=1 sh tools/build-native.sh device integer
```

The option is rejected for the emulator profile: ESP-EMU does not qualify the
physical Tab5 panel, expander or PHY. ESP-IDF v5.4.4 headers are required for
the opt-in C pad/PHY shim; the default native ELF can still build without them.
All higher-level I2C and board logic stays in host-testable Zig.

The source-bound native image audit is still required and is not relaxed.
Runtime code/mutable data remain in SRAM, with no RTOS/SDK driver symbols and
no floating-point instructions in the integer profile. The immutable mask
bytes share the existing second read-only mapped segment; no additional Flash
mapping or partition is introduced.

`NIHOS_NATIVE_DISPLAY_PREP` contains:

| Field | Meaning |
| --- | --- |
| `status` | 1 = preparation complete; 2 = failed |
| `stage` | 1 expander; 2 touch/panel ID; 3 CPU image/cache; 4 PHY supply; 5 PHY lock/lanes; 6 prepared |
| `panel` | 1 ILI9881C; 2 ST7123; 3 ST7121 |
| `transactions` | Completed I2C transfers |
| `frame_start`, `frame_bytes`, `reserve_bytes` | Private scanout reservation |
| `checksum` | CPU-rendered image FNV-1a, before cache handoff |
| `phy_trim` | Desired DREF in bits 7:0, MUL in bits 15:8 |
| `phy_status` | Bit 0 PLL locked; bit 1 both lanes stopped; sampled before shutdown |
| `scanout`, `backlight` | Always zero for this preparation milestone |
| `error_code` | 1 initial address NACK, 2 data NACK, 3 clock timeout, 4 busy bus, 5 arbitration loss, 6 expander ID, 7 unsupported panel, 8 timer, 9 image geometry, 10 cache handoff, 11 PHY deadline, 12 expander readback, 13 other, 14 repeated-START read-address NACK |

Local host/build checks are recorded in the accompanying
[measurement note](measurements/2026-10-26-native-display-preparation.md).
No device was flashed or reset for this change: the separate filesystem
qualification work retains ownership of its physical-device session.

## Next gate

First capture a physical preparation report with the device idle and its
source/firmware identity recorded. Then implement the selected panel's
licensed DCS initialization table, DPI timings and bridge/GDMA ownership.
Enable the backlight only after a complete, cache-synchronized frame is being
scanned out. Keep frame/underrun polling or interrupts separate from the
existing timer/IPI scheduler lines, and qualify coexistence before claiming
visible native boot graphics. Animation follows the first stable frame.
