# Native P4 → C6 SDIO/AT boot fixture

This fixture owns SDMMC exclusively during boot, while CPU1 is still parked.
It uses native Zig for enumeration, CMD52/CMD53, DMA control, C6 FIFO counters
and the AT controller. A small C shim uses pinned ESP-IDF v5.4.4 LL definitions
for Tab5 pads and clocks. No ESP-IDF application archive, FreeRTOS scheduler,
heap, filesystem or network stack is linked into the P4 application.

It is a separate CPU0-only fixture, not a new normal boot mode. The normal
native startup and `build-native*.sh` scripts remain unchanged. Combining the first
implementation with the full native bootstrap exceeded the current 128 KiB
SRAM contract; this fixture retains that contract instead of enlarging it.

## Build

```sh
sh tools/build-c6-sdio-probe.sh
```

Requires the pinned Zig toolchain and ESP-IDF v5.4.4 tools. Override the SDK
location with `NIHOS_IDF_PATH`; the script checks the SDK tag and rejects
modified HAL/SoC definitions. It builds a separate stock loader/config under
`build/c6-sdio-probe/loader`, compiles only the LL pad shim into the native
application and generates:

- `nihos-c6-probe.elf`: SRAM executable with native startup and fatal traps.
- `nihos-c6-probe.bin`: P4 application image for the rev1/2 device profile.
- `image-audit.json`: SRAM/ROM, integer-only, resolved-symbol and image-digest
  checks, including required C6 fixture function symbols. A baseline kernel
  image cannot pass as a C6 fixture.

The script performs no flashing, reset, serial open or OTA selection. The
compiled profile is not detection of the attached chip revision. The loader
partition table in this build directory does not authorize replacing an
existing device partition table. Preserve the actual P4 layout/images/OTA
state before any device action.

## Preconditions for a physical run

The C6 must be backed up, recoverable and running the matching
[ESP-AT SDIO candidate](../../ports/esp32c6-at/README.md). The probe asserts
the C6 hardware reset pin, so it cannot run alongside another user of that
radio. Do not run it on the ESP-Hosted factory firmware: Ethernet/HCI/Hosted
messages are a different protocol. The physical C6 download/recovery wiring
and flash identity have not yet been confirmed in this work.

These are prerequisites for this **AT-specific fixture**, not for normal Tab5
Wi-Fi use. Stock C6 ESP-Hosted is accessible over internal SDIO without an
external UART. Identify that peer before choosing an update path; ESP-Hosted
also supports transport OTA on compatible firmware. The current AT image does
not fit the 1.5 MiB OTA slots in the official reference factory image, so it
cannot be sent as-is through that path. See the
[revised preflight](../../docs/measurements/2026-10-27-c6-wifi-preflight.md#内蔵接続と更新経路の再確認).

The bootloader must supply the clock tree assumed by the existing native
backend. The probe sets up a private 1 MHz TG0 timer, disables watchdogs for
this bounded fixture and does not enable IRQs or release CPU1. There is no
concurrent microSD access. Both SDMMC slots share controller/DMA state: this
prototype must not be attached to a running storage service.

## Intended sequence and evidence

1. Assert C6 reset, route Tab5 GPIO 8–13 and 15, hold D3 high through CMD0,
   configure the 40 MHz host source, release C6 reset and wait for its boot.
2. Set slot 1 to 1-bit/400 kHz; send CMD0/5/3/7 and validate responses.
3. Enable only function 1, wait for ready, set 512-byte block sizes, then
   switch the slave and host to 4-bit mode at 400 kHz.
4. Drain the fresh peer's startup bytes until a bounded quiet interval without
   discarding the cumulative FIFO accounting state.
5. Run all ten AT profile commands, query version again, then query SYSRAM.
   The default build stops here. The opt-in Wi-Fi build continues as below.
6. Print one `NIHOS_NATIVE_C6` record and an explicit AT pass/fail marker.
   A trap prints a separate fatal record. All paths then halt CPU0.

A pass must include status 1/stage 8, one successful profile negotiation,
two version replies, one valid heap reply and no cleanup failure. A marker
or an image audit alone is insufficient. No physical output is recorded yet.
The ROM-address line identifies linked ABI addresses; it does not claim that
every listed ROM function was executed.

## AP connection and DHCP check

The opt-in build enables station DHCP, queries it back, joins the AP, queries
`CWSTATE` and then `CIPSTA`. Only successful AT completions advance the check.
State 2, station DHCP enabled, and a nonzero unicast IPv4 address with a valid
contiguous mask and same-subnet gateway are required. Disconnect, reset, timeout,
duplicate/malformed fields or a terminal ERROR fail the run. `WIFI GOT IP` alone
does not pass. These AT replies are firmware-reported configuration evidence;
the fixture does not capture the DHCP exchange or test Internet reachability.

Create a local JSON file with mode 0600. Use either
`{"ssid":"YOUR_2_4_GHZ_AP","password":"YOUR_PASSWORD"}` or `{"saved":true}`.
The latter reconnects the last **ESP-AT** configuration with bare `CWJAP`.
It does not migrate credentials from factory ESP-Hosted firmware. A fresh AT
flash must use explicit credentials unless its NVS is already provisioned.

```sh
chmod 600 /absolute/path/to/private-wifi.json
NIHOS_C6_WIFI_CONFIG=/absolute/path/to/private-wifi.json sh tools/build-c6-sdio-probe.sh
```

The generated module, image and receipt go into the private, ignored directory
`build/c6-wifi-probe/`. Credentials are embedded in this image: keep all its
artifacts local. The generator rejects public-readable config files and control
bytes, and never prints credentials. `SYSSTORE=0` keeps the test join volatile.
Keep using the already backed-up C6 AT candidate described above.

The join deadline is 30 seconds; each following query has a two-second deadline.
Success requires status 1/stage 10 and a complete `NIHOS_C6_WIFI_PASS` record with
decimal `ip`, `gateway` and `netmask`. On failure, `wifi_step` is 1-based:
enable DHCP, query DHCP, join, query station state, query addresses, done.
Report IP fields use network-order hexadecimal integers. All runs halt after
the result. The Wi-Fi image has been built and audited; no physical AP/IP pass
is recorded yet. See the [current preflight](../../docs/measurements/2026-10-27-c6-wifi-preflight.md).

## DMA and stream contracts

One 64-byte descriptor and 512-byte bounce buffer live in dedicated internal
SRAM with 64-byte alignment. Cache maintenance covers complete owned lines.
RX data is copied only after the command/data completion conditions, DMA
stop/reset and descriptor ownership/error checks. TX input is copied and
flushed before DMA starts. Failure retires the controller, records a cleanup
failure if necessary and keeps the static storage quarantined until reset.

The C6 FIFO address encodes the logical byte count (`0x1f800 - count`),
independently of the transfer's four-byte-aligned DMA length. Padding is
zeroed on TX and never copied to the RX caller. The stream accounts for each
successful FIFO operation exactly once and applies the pinned 512-byte C6
buffer/10-credit profile. Zero credits returns no progress so the AT deadline
still applies. RX counters wrap at 20 bits and TX credits at 12 bits; a
detected discontinuity retires the stream. A complete unobserved counter lap
cannot be detected from those counters alone. The prototype rejects backlog
above 128 KiB; this is a software bound, not a measured hardware capacity.

This is a polling boot experiment. IRQ-driven lifetime handling, shared-slot
arbitration, permanent native service integration, socket/BLE generation
tables, timing/coherency measurements and network coexistence remain open.
