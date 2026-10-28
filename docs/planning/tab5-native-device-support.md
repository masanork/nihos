# Tab5 native device support inventory

2026-10-28, based on main `c54d9dd` (default on-demand devices and public
NTP-to-RTC synchronization), followed by one connected combined-image check.
Compiled availability, physical controller operation and a complete application
service remain separate gates. Hardware inventory follows
[M5Stack's board documentation](https://docs.m5stack.com/en/core/Tab5).
Other active VFS/resource branches are not included in this main inventory.
Card/touch observations retain their original candidate/optical scope.

| Device | Native status in this change | Remaining work |
| --- | --- | --- |
| LCD / backlight / console | Existing normal live display; retained during Wi-Fi/BLE/device polling | Application compositor/input integration |
| PSRAM / dual CPU / timers | Existing normal initialization and ownership | Other memory/scheduler work remains separate |
| C6 Wi-Fi | Default normal service; AP association/DHCP and bounded DNS/UDP public NTP physically observed; connection remains acquired during finite device operations | General TCP/DNS/TLS socket service, sustained mixed-traffic/load testing, global IPv6 qualification and C6 host offload |
| C6 Bluetooth LE | Shared SDIO HCI; real passive advertisements and acknowledged scan stop | C6 host offload, GATT/SMP/bonding, peripheral list/handles, HID keyboard |
| RX8130CE RTC, 0x32 | Validated UTC calendar; public NTP write/readback, advancing RTC and no-NTP warm-reset retention physically observed; failed NTP request leaves RTC usable until recovery | Time/settings UI; natural six-hour resync and drift, cold backup retention, VLF initialization, alarm/wakeup |
| INA226, 0x41 | Manufacturer/die verified; bus voltage and signed raw shunt voltage | Board shunt/calibration policy, current/power and battery service |
| BMI270 IMU, 0x68 | Native configuration/init and +/-4 g, +/-500 dps raw acquisition; continuous readings alongside connected Wi-Fi/NTP and finite device requests | Controlled movement, gyro bias/calibration, board axis mapping, FIFO/IRQ, application input service |
| PI4IOE5V6408, 0x43/0x44 | Existing display/C6 power sequencing; preserved handoff to shared I2C | Unified runtime GPIO/power service |
| Touch, GT911 or ST7123 family | Native ST7121 diagnostic/card profiles; earlier physical candidate confirmed four-quadrant contacts and releases | Normal application input, other panel/multitouch qualification, IRQ23 |
| ES8388 / ES7210 audio | Included in normal build, idle until explicitly requested; finite speaker and repeated microphone/controller cleanup observed with Wi-Fi connected; overlap rejected and lazy 1536-byte I2S storage reused | Audible/acoustic/slot calibration, long-duration/repeated stress, streaming/mixer and application API |
| SC2356 camera | No native capture service | Sensor setup, MIPI CSI/ISP, DMA and buffer ownership |
| microSD | Existing bounded native read-only boot fixtures | Runtime filesystem, removal/reinsertion, SDMMC arbitration with C6 |
| USB-A host / USB-C OTG | Opt-in native USB-A PaSoRi/CCID card profiles landed; earlier candidate read/photo physically confirmed | Merged candidate retest; USB-C role/power and other USB classes |
| RS485 SIT3088 (TX20/RX21/DIR34) | Included in normal build, idle until requested; repeated internal UART exchanges with DIR low and stopped cleanup observed alongside connected services | External A/B peer/transceiver/direction timing, application streaming service and optional DMA |
| Buttons / charging / USB power outputs | Hardware power behavior and limited boot expander setup | Debounced input and explicit charger/power policy |

The normal image initializes display/PSRAM/SMP, C6 transport and board sensor
polling. With configured Wi-Fi, it also synchronizes UTC RTC through public NTP.
Speaker, microphone and RS485 are requestable without boot-time playback,
recording or bus transmission. This does not enable camera capture or integrate
USB/card/touch qualification profiles into a normal application input service.

Evidence and contracts:

- [Default on-demand driver policy](../adr/0052-default-on-demand-device-drivers.md)
- [Public NTP-to-RTC policy](../adr/0053-network-time-to-rtc.md)
- [Connected device coexistence and NTP recovery](../measurements/2026-10-28-connected-devices.md)
- [RTC write/readback and no-NTP warm retention](../measurements/2026-10-28-network-rtc-sync.md)

The next application-input gaps are normal touch integration and BLE keyboard
input. BLE needs a known HID-over-GATT peer, followed by connect, service/report
discovery, required security and report subscription. A Bluetooth Classic-only
keyboard/headphone is not a BLE qualification peer. Camera capture and current/
battery policy need their own hardware/register and buffer-ownership work.

Protocol/register references: [ESP-Hosted](https://github.com/espressif/esp-hosted-mcu)
(exact revisions in `provenance.toml`), [Epson RTC manual](https://download.epsondevice.com/td/pdf/app/RX8130CE_en.pdf),
[TI INA226 datasheet](https://www.ti.com/lit/ds/symlink/ina226.pdf),
[Bosch BMI270 datasheet](https://www.bosch-sensortec.com/media/boschsensortec/downloads/datasheets/bst-bmi270-ds000.pdf).
