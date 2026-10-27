# ADR 0047: Default native connectivity and board device services

- Date: 2026-10-27
- Status: implemented; Wi-Fi, BLE discovery and sensor presence physically observed
- Extends: [ADR 0046](0046-native-network-lease-lifecycle.md)

## Build and settings boundary

`sh tools/build-native.sh device` now selects the normal integer display,
PSRAM200 and live console profile, with the C6 service enabled. Explicit
qualification, display fixtures, storage and emulator profiles retain their
own settings. `NIHOS_NATIVE_NETWORK=0` disables the C6 service. The low-level
`build-native-elf.sh` remains an SDK-free qualification/link tool and does not
implicitly select physical peripherals.

`NIHOS_C6_WIFI_CONFIG=/absolute/private/wifi.json` is an optional initial
provider. The existing mode-0600 JSON format accepts either `ssid`/`password`
or explicit `saved:true`. Missing configuration means **unconfigured**, with
no Wi-Fi initialization or association RPC. It never implies saved credentials.
The C6 transport and BLE discovery can still run. Runtime status explicitly
distinguishes a compiled driver, configured station, acquired address and BLE
controller state.

`hosted_station.Configuration` owns bounded copies of credentials, validates
before replacement and clears the previous buffers. CPU0
`network_service.configure()` revokes addresses/output and starts a new C6
epoch when settings change. A future settings/SQLite service can supply this
API; persistent storage, a settings UI and application IPC are not added here.
Generated credentials and firmware stay in ignored private build directories.

## BLE controller and discovery

The exclusive SDIO owner demultiplexes HCI interface 4 alongside RPC and Wi-Fi.
Wi-Fi output has priority; otherwise one complete BLE command can be sent per
poll. Retained output observes transport backpressure. Controller command
credits, matching Command Complete/Status, malformed lengths and deadlines are
handled independently from Wi-Fi. A C6 reset drops all BLE state.

The factory 1.4.1 source initializes and enables Bluetooth at boot. It predates
FeatureControl RPC 387. That exact, identified version uses its existing
controller; other versions attempt correlated Bluetooth init/enable RPCs,
whose failure does not disable Wi-Fi. The advertised capability alone is not
successful controller qualification. C6-to-P4 HCI packets retain H4 inside the
payload; P4-to-C6 puts it in header byte 11. Both directions are tested.

The implemented profile initializes HCI, configures event masks, reads LE
features, performs ten seconds of passive legacy scanning, then requires an
acknowledged scan-disable command. It reports advertisement counts without
logging nearby device addresses or payloads. CPU0 can request another bounded
session through `scanBluetooth()`. This profile does not expose a discovery
list or connections to applications yet.

This is a P4 controller/GAP bring-up host. The intended **C6 TCP/IP and BLE
host offload** in ADR 0043 is unchanged and remains unfinished. ACL/L2CAP,
ATT/GATT, SMP, bonding, privacy, HID input and LE Audio are not implemented by
this change. BLE keyboard/HID over GATT is the next useful integration target
once a known peripheral is available. Ordinary Bluetooth Classic headphone
audio is outside the C6's BLE capability.

## Shared board I2C and RTC

After display/power setup, CPU0 polls one bounded RTC/power/IMU job per second
with interrupts enabled. CPU1 and IRQ handlers never access this bus. Runtime
operations never clear or reset a busy bus. External keyboard I2C uses separate
GPIO0/1. The C6 power shim now releases GPIO31/32 and restores a low output
latch before handing back to the Zig open-drain master; retaining its high
latch prevented all later sensor transfers on the first physical candidate.

The RX8130CE driver reads a continuous register burst, validates BCD, dates
(2000–2099), one-hot weekday, VLF and STOP/TEST, and exposes an explicit set API.
Setting preserves battery/alarm/timer policy; errors attempt to leave STOP set
so a partial calendar cannot qualify. Failure to assert STOP is reported.
The calendar-only set API rejects VLF until a separate, explicit board
initialization has restored all required registers; it never clears VLF to
claim recovery from an uninitialized oscillator/register state.
Normal boot never sets time from the host/build clock, clears RTC flags,
enables backup charging, or configures wakeup/alarm power behavior.

INA226 manufacturer/die ID, bus voltage and signed shunt voltage are read
without modifying calibration. Current in amperes, charge percentage and
battery policy are not inferred. BMI270 reports chip ID and initialization
status; configuration upload and acceleration/gyro sampling remain separate.

## Qualification

See the [device inventory](../planning/tab5-native-device-support.md) and
[physical checkpoint](../measurements/2026-10-27-default-connectivity-devices.md).
RTC set/recovery is host-tested and RV32-codegenerated; its persistent clock
setting and backup/wakeup behavior still need device qualification. The board's
existing calendar has an invalid weekday and is deliberately not qualified as
wall time. BLE discovery is distinct from HID/GATT interoperability.
