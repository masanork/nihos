# 0025: Native PSRAM supply and command-data qualification

Status: accepted for the native boot fixture, 2026-10-26.

## Decision

Extend ADR 0024's read-only discovery with a dedicated LDO channel 2 startup
path, verified device-mode programming and bounded 32-bit command reads and
writes. CPU0 owns the entire sequence before CPU1 release. Internal SRAM
remains the only allocator; there is no CPU mapping of PSRAM yet.

The implementation uses pinned ESP-IDF v5.4.4 primary facts:

- [LDO voltage/ownership definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/hal/esp32p4/include/hal/ldo_ll.h) and [regulator startup](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_hw_support/ldo/esp_ldo_regulator.c).
- [eFuse calibration fields](https://github.com/espressif/esp-idf/blob/v5.4.4/components/soc/esp32p4/register/hw_ver1/soc/efuse_reg.h) and [PMU LDO registers](https://github.com/espressif/esp-idf/blob/v5.4.4/components/soc/esp32p4/register/hw_ver1/soc/pmu_reg.h), checked against their revision-3 equivalents.
- [AP hex device commands and mode registers](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_psram/device/esp_psram_impl_ap_hex.c).

No C PSRAM/regulator implementation or new ROM function is linked.

## Supply and timer ownership

Channel 2 is VO2, software unit 1, PMU LDO slot 3. Only this 1.8 V domain
is configured. With a nonzero eFuse block version and both VO2 trim fields
present, use the factory DREF/MUL fields. Otherwise use DREF=6, MUL=5, the
first exact 1.8 V solution in the nominal VO2 model: 0.8 V times 2.25.
This deliberately is not a generic adjustable-voltage regulator API.

Select software ownership and the reference path, program the analog
fields with ripple suppression, then enable the output. Read back all
owned fields, including the bypass selector. Unrelated delay/current-limit
bits are preserved. A failed readback prevents PSRAM commands.

CPU0 temporarily leases its stopped 1 MHz TG0 timer for a 1 ms settling
interval. Capture handshakes and the outer wait both have poll limits.
Stop the timer on every exit, then reconfigure/reload it for the scheduler's
first deadline before CPU1 starts. No timer interrupt is enabled on the CPU
during this lease. A settling failure prevents command execution.

Register readback and this boot delay do not measure analog voltage,
power-good or the board's physical startup timing. The calibration report
means that factory trim fields were selected, not that voltage was measured.

## Device modes and data capability

Only a supported, stable discovered identity may be configured. Preserve
unrelated mode bits while selecting fixed read latency 2, write latency 2
and initial x8 operation (`MR0 & 0x3f = 0x28`, `MR4 & 0xe0 = 0x40`,
`MR8 & 0x4f = 0x0b`). Verify all written fields and the unchanged identity.
Capacity for command-data access stays zero until these reads agree.

The private transaction primitive permits four opcodes: mode read/write
`0x4040`/`0xc0c0` and synchronous data read/write `0x0000`/`0x8080`.
The command path uses octal DDR, CS1, 16-bit command and 32-bit address.
Mode writes have no dummy phase; data write/read use 8/18 dummy bits and
32 data bits. The exploratory clock remains nominal XTAL/2 from ADR 0024.
An empty polling budget, busy controller or invalid address cannot start a
new transfer. Timeout poisons reuse as before.

The public word API requires verified capacity, 4-byte alignment and a
complete word inside the detected device. Rejected requests consume no
transactions. This capability permits explicit controller commands only;
it does not create an external arena or authorize CPU/DMA memory accesses.

## Boot data exercise

Before any external-memory consumer exists, sample address 0, every word
address that is a power of two within the device, and its final word. There
are 22 through 26 distinct addresses for 4 through 64 MiB devices. For each
of two complementary patterns, write the complete address set first, then
read the complete set. An address-derived value distinguishes locations so
aliasing cannot hide behind immediate write/read pairs. A mismatch revokes
command capacity and faults the owner. This exercise is destructive to its
PSRAM samples and never writes Flash.

Host fault models drop mode writes, alias each sampled address line,
corrupt returned data and stall data writes. Boundary tests require the
final word to succeed while rejecting misaligned/overflowing/outside words.
The model tests controller policy and sequencing, not electrical behavior.

Native reports distinguish four discovery reads from total command counts.
A populated device requires nine mode-configuration transactions and four
transactions per sampled address for its two write/read passes. An absent
die must skip all mode/data writes. The log validator requires supply
readback, settling, mode values, sample counts and complete data accounting,
then the existing scheduler/SRAM/IPI/FP results. The compiled FP image is
also exercised with a populated 32 MiB die.

## Remaining boundary

There is still no MMU mapping, external allocator registration, cache or DMA
ownership qualification. Sparse command samples do not establish complete
memory integrity, retention or bandwidth. Physical supply/clock timing,
x16 operation, MPLL/DLL calibration and high-speed operation remain separate
gates. Initial CPU mapping should retain a conservative command/clock policy
before performance tuning. No physical device was accessed for this stage.
