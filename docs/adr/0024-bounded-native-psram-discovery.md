# 0024: Bounded native PSRAM command discovery

Status: accepted for the emulated native boot fixture, 2026-10-26.

## Boundary

Native SRAM allocation from ADR 0023 remains the only allocator. This step
adds die identification through the dedicated PSRAM command controller,
before CPU1 release. It does not initialize PSRAM for CPU loads/stores or
register an external heap. The ESP-IDF hosted backend remains an oracle.

The driver is original Zig using protocol/register facts from pinned primary
sources. It neither links the C PSRAM implementation nor adds ROM SPI calls:

- [ESP-IDF v5.4.4 AP hex driver](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_psram/device/esp_psram_impl_ap_hex.c): register reads, vendor identifiers, density encoding and good-die field.
- [Revision-1 command registers](https://github.com/espressif/esp-idf/blob/v5.4.4/components/soc/esp32p4/register/hw_ver1/soc/spi1_mem_s_reg.h) and the corresponding revision-3 headers: MSPI3 user command, FIFO, DDR and phase fields.
- [PSRAM clock/control definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/hal/esp32p4/include/hal/psram_ctrlr_ll.h): independent PSRAM clock tree and shared MSPI2/3 CS timing.
- [ESP-EMU 0.50.0 PSRAM fixture](https://github.com/espressif/esp-emulator/blob/v0.50.0/test_apps/psram/main/test_psram.c): the model reports the selected die density through its mode registers. Its RAM backing is not electrical/cache evidence.

## Command contract

The native setup selects XTAL/2 for a nominal 20 MHz command clock,
enables/resets the dedicated PSRAM controller and configures dedicated pads,
DQS inputs and CS setup/hold. Flash MSPI0/1 and their CS0 are untouched.
Controller/pad registers are written; commands sent to the die are read-only.

`Controller.readPair` permits only MR0/MR1 and MR2/MR3 reads: command
`0x4040`, 16-bit command, 32-bit address, eight dummy bits and 16 input bits
in octal DDR mode on CS1. Each command has an explicit maximum poll count.
A busy controller or invalid request is left untouched. A completion timeout
poisons that controller object: another command requires a hardware reset
and a new owner. The boot wrapper uses 100,000 polls, which is a bound on
iterations rather than a measured wall-clock latency guarantee.

The FIFO is seeded with an invalid identity before each command. A
controller that clears its start bit without returning data must not turn
old FIFO contents into a believable absent/detected result. Both pairs are
read twice. Changing values publish no capacity. Known vendors (`0x0d`,
`0x1a`), good-die value 6 and a recognized density are all required for a
detected result. Unsupported fields never receive a guessed default size.

| MR2 density | Reported bytes |
| --- | ---: |
| 1 | 4 MiB |
| 3 | 8 MiB |
| 5 | 16 MiB |
| 7 | 32 MiB |
| 6 | 64 MiB |

`NIHOS_NATIVE_PSRAM` reports raw pairs, status, detected bytes, successful
transaction count, mapped bytes and allocatable bytes. Both latter values
must remain zero. The smoke validator independently decodes the identity,
compares it with the explicitly requested emulator size, requires four
completed reads and rejects duplicate/missing reports or early exposure.
All existing SRAM, scheduler, IPI and FP gates remain required afterwards.

## Qualification and next stage

Host tests exercise delayed/stuck completion, exhausted/empty poll budget,
busy ownership, invalid addresses, unchanged FIFO and unstable identity.
These are register-contract tests, not an electrical simulator. The native
smoke runs the absent case in all three task modes and five populated sizes
in integer mode. Per-size logs/reports have independent paths. Manual CI
retains the whole matrix; normal CI still links/audits both revision profiles.

The command fixture is qualified in ESP-EMU only. It does not yet reproduce
the official MPLL/DLL and high-speed calibration sequence. In particular,
[the PSRAM/MPLL supply configuration](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_hw_support/port/esp32p4/Kconfig.ldo)
reserves LDO channel 2 at 1.8 V; the
[official acquisition path](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_hw_support/clk_ctrl_os.c)
initializes that supply. Native LDO ownership/eFuse calibration and board
power sequencing remain to be implemented and physically qualified. An
emulated absent response therefore does not establish how an unpowered
physical board would behave. A successful device-profile image build
qualifies compilation/layout only.

The next stages are supply/clock startup, device mode programming and
bounded command-data round trips, then timing calibration, MMU/cache mapping
and cross-core visibility. Expose a memory region only after those gates
pass. Data reads/writes, density alias checks, CPU cache behavior, DMA and
physical timing are not covered by mode-register detection.
