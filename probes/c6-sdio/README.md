# Native P4 → C6 SDIO/AT boot fixture

For the built-in C6's **existing ESP-Hosted firmware**, use the Hosted mode
below. It requires no C6 firmware replacement or external USB–TTL adapter.

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
the result. The AT-mode Wi-Fi image has been built and audited; no physical AP/IP pass
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

## Existing C6 firmware: Hosted station mode

```sh
NIHOS_C6_PROTOCOL=hosted sh tools/build-c6-sdio-probe.sh
```

This builds `build/c6-hosted-probe/` and defaults to the AP already saved in
C6 NVS. To supply credentials for this run only, also set
`NIHOS_C6_WIFI_CONFIG=/absolute/path/to/private-wifi.json` using the 0600 JSON
format above. Hosted uses protobuf byte fields for SSID/password. The image
contains any supplied credentials and stays private. The build opens no port.

The native P4 fixture enables C6 power through a boot-exclusive, open-drain
I2C transaction (PI4IOE5V6408 0x44 P0), preserving all other register bits.
It does not reset either expander or change charger settings. It then resets
C6, enumerates SDIO, opens Hosted's scratch-7 datapath, validates the INIT
chip ID (C6=13), rejects advertised packet mode, replies with host capabilities,
and queries the firmware version. Older peers lacking that query can continue
with a distinct UID; the report retains `fw_known=0` in that case.

One RPC at a time initializes Wi-Fi, selects RAM configuration storage, sets
station mode, starts Wi-Fi, disables power save, reads the station MAC,
optionally supplies AP configuration and requests association. Replies must
match both UID and message ID. The connection event can precede its RPC reply.
Disconnect invalidates the run, including after an ACK in the same FIFO read.

P4 then sends DHCP Discover/Request Ethernet packets and validates Offer/ACK
against xid, MAC and the selected server. A successful ACK needs a valid
address, subnet mask, gateway and nonzero lease time. IPv4 checksums and any
nonzero UDP checksum are checked; malformed DHCP is counted and ignored.
The client has bounded retries and a 45-second acquisition budget. RPC waits
are five seconds, association is 30 seconds and the whole loop is bounded to
100 seconds. No renewal, ARP conflict detection, DNS, TCP, Internet test or
permanent network service is implemented. DHCP runs on **P4** in this mode;
this does not demonstrate the eventual C6 TCP/IP offload.

`NIHOS_C6_HOSTED_WIFI_PASS ip=... gateway=... netmask=...` requires status 1,
stage 12, the C6 INIT identity, successful Wi-Fi RPCs and a matching DHCP ACK.
The report records firmware identity when available, phase, last RPC/status,
disconnect reason and lease/server. Never accept a marker from a different
candidate or protocol. The Hosted image audit requires its actual execution
function and power-enable function; an AT-only image must fail that audit.

The transport is the bounded streaming profile: 512 bytes per SDIO operation,
one complete <=512-byte TX packet per 1536-byte peer buffer, credit limit 64,
4096-byte frame assembly, no serial fragments. Nonzero Hosted checksums are
validated; zero checksums are counted as unchecked for legacy peers. An absent
SDIO mode tag is reported as 255 (unknown), not proof of streaming mode.
Protocol/DMA/counter errors stop the experiment. This profile still needs
physical validation, including partial FIFO reads, coherency and cold boot.

Confirm the actual P4 firmware/layout/OTA selection before a device run. A spare
application slot can isolate the experiment; the user's factory-only development
layout was tested by replacing its factory app under their authorization, with
no full-flash backup per their explicit instruction. Do not flash the generated
loader/table over the device. The [physical run](../../docs/measurements/2026-10-27-c6-hosted-device.md)
identified C6 Hosted 1.4.1. The saved AP was not found (reason 201), then explicit
private AP configuration produced an association event and DHCP ACK with
`10.193.127.151/24`. This is one boot-fixture acquisition pass, not normal OS
service integration, renewal, Internet reachability or a power-cycle qualification.

## IPv6 boot mode

Set `NIHOS_C6_PROTOCOL=hosted NIHOS_C6_IPV6=1` to build private
`build/c6-ipv6-probe/`, using the same optional AP JSON. DAD, MLDv2 reporting,
RS/RA/SLAAC, neighbor resolution and ICMPv6 run beside IPv4 DHCP. The
`NIHOS_C6_IPV6_LINK_READY` marker synchronizes external peer tests.

`NIHOS_C6_IPV6_PASS` requires preferred link-local/SLAAC addresses and a matching
outgoing router Echo reply. `PARTIAL` records lesser progress, including no RA.
IPv4 markers retain their DHCP-only meaning; IPv6-only success is supported.
See [scope and physical evidence](../../docs/measurements/2026-10-27-native-ipv6.md).
