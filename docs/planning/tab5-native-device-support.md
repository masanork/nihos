# Tab5 native device support inventory

2026-10-27, scoped to this branch based on main `1f43a4d`. Presence, a read
operation and a complete application service are different gates. Hardware
inventory follows [M5Stack's board documentation](https://docs.m5stack.com/en/core/Tab5).
ESP-IDF bring-up drivers and other active USB/VFS branches are not implicitly
native main implementations.

| Device | Native status in this change | Remaining work |
| --- | --- | --- |
| LCD / backlight / console | Existing normal live display; retained during Wi-Fi/BLE/device polling | Application compositor/input integration |
| PSRAM / dual CPU / timers | Existing normal initialization and ownership | Other memory/scheduler work remains separate |
| C6 Wi-Fi | Default in public normal build; AP association, DHCPv4, IPv6 link-local | TCP/DNS/TLS sockets, global IPv6 qualification, C6 TCP/IP offload |
| C6 Bluetooth LE | Shared SDIO HCI; real passive advertisements and acknowledged scan stop | C6 host offload, GATT/SMP/bonding, peripheral list/handles, HID keyboard |
| RX8130CE RTC, 0x32 | Burst read, validation and explicit read/set API; presence and ticking raw registers observed | Set API physical qualification; settings/time UI; correct persistent calendar; backup/alarm/wakeup |
| INA226, 0x41 | Manufacturer/die verified; bus voltage and signed raw shunt voltage | Board shunt/calibration policy, current/power and battery service |
| BMI270 IMU, 0x68 | Chip ID 0x24 physically read, reports not initialized | Licensed config blob/init, accel/gyro acquisition, axis mapping |
| PI4IOE5V6408, 0x43/0x44 | Existing display/C6 power sequencing; preserved handoff to shared I2C | Unified runtime GPIO/power service |
| Touch, GT911 or ST7123 family | ESP-IDF backend has touch bring-up; native input service absent | Panel-specific native protocol, coordinates, IRQ23 and input events |
| ES8388 / ES7210 audio | No native streaming service | Codec/mic setup, I2S DMA, mixer, record/playback |
| SC2356 camera | No native capture service | Sensor setup, MIPI CSI/ISP, DMA and buffer ownership |
| microSD | Existing bounded native read-only boot fixtures | Runtime filesystem, removal/reinsertion, SDMMC arbitration with C6 |
| USB-A host / USB-C OTG | Other worktrees under development; not included here | Land and physically qualify relevant classes, power and role control |
| RS485 SIT3088 (TX20/RX21/DIR34) | No native service | UART/DMA, direction switching and loopback with a peer |
| Buttons / charging / USB power outputs | Hardware power behavior and limited boot expander setup | Debounced input and explicit charger/power policy |

The next useful vertical feature is BLE keyboard input: discover a known
HID-over-GATT peripheral, connect, enumerate HID services, establish security
where required, subscribe to reports and deliver normal input events. A
Bluetooth Classic-only keyboard/headphone is not a substitute for a BLE peer.

Protocol/register references: [ESP-Hosted](https://github.com/espressif/esp-hosted-mcu)
(exact revisions in `provenance.toml`), [Epson RTC manual](https://download.epsondevice.com/td/pdf/app/RX8130CE_en.pdf),
[TI INA226 datasheet](https://www.ti.com/lit/ds/symlink/ina226.pdf),
[Bosch BMI270 datasheet](https://www.bosch-sensortec.com/media/boschsensortec/downloads/datasheets/bst-bmi270-ds000.pdf).
