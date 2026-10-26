# Native Tab5 USB / CCID boot probe

`NIHOS_NATIVE_USB=1` enables a bounded CPU0-only USB diagnostic before CPU1
starts. The application links no ESP-IDF USB host stack, FreeRTOS, SDK heap,
or interrupt handler. The existing stock ESP-IDF loader still boots it.

```sh
NIHOS_NATIVE_USB=1 sh tools/build-native.sh device integer
```

The small C boundary in `probes/usb_native/pads.c` uses pinned ESP-IDF v5.4.4
LL register definitions to set up GPIO31/32 and the UTMI PHY. It makes no SDK
runtime calls. The USB-A supply is enabled through bit 3 of I2C expander
`0x44`, preserving other bits. The generic boot I2C module was reused from
the concurrent native-display worktree as a read-only snapshot (SHA-256
`d4a9af12fdde78b8ddedfc5f9d4620d1092efea602fea01c05b7ab8a6d6fa592`).
That worktree and its ongoing edits were not changed.

`src/soc/esp32p4/usb_host.zig` owns one root port and one polled DWC2
scatter/gather DMA channel. Transfer storage is fixed internal SRAM: a
512-byte data buffer and a 512-aligned descriptor list. ROM cache clean and
invalidate operations establish DMA ownership. The parser consumes bounded
copies; malformed lengths and descriptors are rejected before configuration.
SETUP, data and status stages use the required direction and DATA PID.
Each bulk pipe retains its DATA toggle between requests.

The probe debounces and resets the root port, reads the initial/device/config
descriptors, assigns address 1, and sets the first configuration. For a
single-slot CCID interface (`0b/00/00`) it sends three
`PC_to_RDR_GetSlotStatus` requests with successive sequence numbers and checks
the matching `RDR_to_PC_SlotStatus` responses. No card power-on, activation,
APDU, PIN, authentication, or persistent-storage request is sent.

Port detection is limited to one second; transfer stages to 500 ms; channel
halt to 50 ms. A failed halt poisons the controller to prevent DMA-buffer
reuse. The PHY/controller is reset and clock-gated on every exit from USB
enumeration before normal native boot continues. `dma_stopped=1` records this
cleanup path; it is not an electrical bus trace. USB5V_EN remains enabled.

The implementation currently supports the rev1/2 device build profile,
directly attached Full/High Speed devices, configurations up to 512 bytes,
and one CCID slot. It rejects the emulator/rev3 USB option; default builds
keep USB disabled. It is a boot diagnostic, not a scheduled USB service,
hotplug framework, hub driver, periodic interrupt endpoint driver, or
complete CCID implementation. The vendor interface on this PaSoRi is unused.

## Physical qualification

After installing the generated bootloader/partition/app files, using the
actual current port and checking that no other process owns it:

```sh
python tools/capture-native-usb.py /dev/cu.usbmodem101 \
  /absolute/path/to/evidence build/native-device/image-audit.json
```

This performs three RTS resets, retains the complete raw serial stream and
the stream beginning at the fresh ROM boot banner, and runs the existing
strict native execution checker with the added `usb` requirement. It requires
successful USB/CCID, DMA cleanup, and the subsequent native 300-round/SMP/
IPI/owned-memory checks. Earlier bytes emitted during the reset remain in
the `.raw.log` artifact and are excluded from the fresh boot's `.log`.

Host tests exercise the retained PaSoRi descriptor, malformed/truncated data,
CCID length/slot/sequence/status validation, DMA residuals, disconnect/stall
cleanup, and refusal to reuse a channel after halt timeout. These model tests
do not qualify physical unplug, STALL, overcurrent or timeout recovery.

References: [ESP-IDF v5.4.4 USB host](https://docs.espressif.com/projects/esp-idf/en/v5.4.4/esp32p4/api-reference/peripherals/usb_host.html),
[USB-IF CCID 1.1](https://www.usb.org/sites/default/files/DWG_Smart-Card_CCID_Rev110.pdf).
No MeOS source is imported; its repository remains reference-only per
`provenance.toml`.
