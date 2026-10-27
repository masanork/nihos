# Tab5 USB-A enumeration probe

A temporary **ESP-IDF-hosted diagnostic**, separate from the native nihOS
firmware. It uses ESP-IDF v5.4.4's USB Host Library, without a device-specific
class driver, to identify a connected reader before choosing its protocol.
This is not a native nihOS USB driver or evidence of card communication.

The probe enables USB-A VBUS through PI4IOE5V6408 at I2C address `0x44`,
bit 3, preserving other pins and restoring the three changed registers on
normal completion. It does not reset the IO expander or initialize the screen,
PSRAM, SD card, Wi-Fi, or camera. USB-A uses the P4 high-speed OTG/UTMI core;
USB-C Serial/JTAG remains the diagnostic console.

Over 30 seconds it reports device VID/PID, cached manufacturer/product strings,
speed, standard descriptors, interface class/subclass/protocol, endpoints,
and the complete configuration descriptor in hex. `connected=1` without a
`DEVICE` record distinguishes physical attachment from successful enumeration.
An interface class of `0x0b` indicates Smart Card; vendor-specific devices need
their own protocol investigation. No interface is claimed and no card command
is sent. USB enumeration itself performs standard device configuration.

## Build and run

From the repository root, after exporting ESP-IDF v5.4.4:

```sh
idf.py -C probes/usb_scan -B "$PWD/build/usb_scan" \
  -D SDKCONFIG="$PWD/build/usb_scan/sdkconfig" build
```

Before installing, rediscover the serial port, check its owner, and identify
the chip. If the current firmware needs to be preserved, save the **current**
Flash and its hash. Do not assume an earlier device test's firmware is still
installed. Use the generated `flasher_args.json` to identify the bootloader,
partition table and application that installation will replace.

After installing the diagnostic with the generated flash arguments:

```sh
python tools/capture-usb-scan.py /dev/cu.usbmodem101 /absolute/path/scan.log
```

The capture resets the device and fails if the bounded probe does not finish.
It does not install firmware. The diagnostic can be left installed for another
scan after reset, or replaced with the next firmware. If restoration was
requested, restore every touched Flash sector from the fresh backup and verify
the restored bytes. A reset or crash before completion can leave USB power
enabled until another firmware reconfigures the expander.

## References

- [Tab5 hardware and pin map](https://docs.m5stack.com/en/core/Tab5)
- [ESP-IDF v5.4.4 USB Host Library](https://docs.espressif.com/projects/esp-idf/en/v5.4.4/esp32p4/api-reference/peripherals/usb_host.html)
- [USB-IF defined interface classes](https://www.usb.org/defined-class-codes)

Power-register semantics were checked against the existing, separately licensed
Espressif Tab5 BSP and PI4IOE5V6408 component in `managed_components/`. No MeOS
USB host implementation is included.
