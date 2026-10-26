# Tab5 USB-A IC-card reader enumeration

Physical-device observation on 2026-10-26, using a standalone ESP-IDF v5.4.4
diagnostic in `probes/usb_scan`, built from the isolated worktree
`/private/tmp/nihos-usb-scan`. Native nihOS does not gain USB support from this
test. No smart-card class driver, card command, APDU, or card read was run.

## Observed device

| Field | Observed value |
| --- | --- |
| USB manufacturer | SONY |
| USB product | FeliCa Port/PaSoRi 4.0 |
| VID:PID | `054c:0dc9` |
| USB speed | Full Speed |
| Configuration | 1, 116 descriptor bytes, two interfaces |
| Advertised maximum power | 200 mA (descriptor value, not a measurement) |
| Interface 0 | `0b/00/00` Smart Card / CCID |
| Interface 0 endpoints | Bulk IN `0x81`, Bulk OUT `0x01`, Interrupt IN `0x83` |
| Interface 1 | `ff/00/00` vendor specific |
| Interface 1 endpoints | Bulk IN `0x82`, Bulk OUT `0x02` |
| Endpoint maximum packet sizes | 64 bytes |

The first device record arrived about 0.64 seconds after boot. All periodic
status samples through the 30-second window reported one enumerated device
and an attached root port. The probe ended normally with
`NIHOS_USB_SCAN_END enumerated=1 power_restored=1`.

The board's PI4IOE5V6408 at I2C `0x44` controls USB-A VBUS with bit 3.
The probe read-modify-writes output/direction/high-impedance registers, without
resetting other expander pins. Their initial values were `08/08/f7`, so VBUS
was already enabled. Those values were restored on normal completion.

## Firmware and evidence

The serial port was `/dev/cu.usbmodem101`, with no existing owner before use.
esptool identified ESP32-P4 revision 1.3, 40 MHz crystal and USB Serial/JTAG.
The diagnostic application is 239,760 bytes, SHA-256
`8db4a28d8505740e515ab298b5f70a6547a88963de97c7a1ae028ee26b5fe728`.
The bootloader, partition table and app were written at `0x2000`, `0x8000`
and `0x10000`; esptool verified all three data hashes. The user requested
leaving restoration aside because another firmware will be installed next.
**The diagnostic is left installed**, and runs another scan after reset.
The display is not initialized by this probe.

Raw boot/descriptor log, flash log, firmware artifacts and hash receipt:
`/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-usb-scan/`.
The complete raw configuration descriptor is preserved in `scan-1.log`.

Next implementation boundary: native USB PHY/controller initialization and
EP0 enumeration, followed by interface 0's CCID transport. Actual reader/card
operations require separate verification. Interface 1 is vendor specific;
enumeration does not establish which reader features it exposes.

References: [ESP-IDF USB Host Library](https://docs.espressif.com/projects/esp-idf/en/v5.4.4/esp32p4/api-reference/peripherals/usb_host.html),
[USB-IF CCID 1.1](https://www.usb.org/sites/default/files/DWG_Smart-Card_CCID_Rev110.pdf).
