# Tab5 native USB / PaSoRi CCID physical result

Date: 2026-10-26. Application source: `81dc067`, branch
`codex/tab5-usb-native`, isolated worktree `/private/tmp/nihos-usb-scan`.
The existing dirty main and concurrent display/storage worktrees were not
modified. This branch uses committed native PSRAM/storage work at `0ce1537`
as its base; the earlier hosted USB diagnostic is retained separately.

## Physical result

ESP32-P4 revision 1.3, `/dev/cu.usbmodem101`, USB-C Serial/JTAG console.
SONY FeliCa Port/PaSoRi 4.0 remained directly attached to USB-A.
Three RTS-reset boots of the **same final image** passed the strict native
execution checker with the added `usb` requirement. These were powered resets,
not cold power-on or physical unplug/replug tests.

| Observation | Boot 1 | Boot 2 | Boot 3 |
| --- | --- | --- | --- |
| VID:PID | `054c:0dc9` | `054c:0dc9` | `054c:0dc9` |
| Bus / configuration | Full Speed, 116 bytes, 2 interfaces | same | same |
| CCID interface endpoints | `81/01/83` | same | same |
| Completed USB transfer stages | 22 | 22 | 22 |
| Validated CCID slot-status queries | 3 | 3 | 3 |
| CCID response card state | absent (2) | absent (2) | absent (2) |
| USB return / DMA stop path | success | success | success |
| Subsequent dual-core rounds | 300 | 300 | 300 |
| Subsequent lifecycle, IPI/WFI, owned memory | pass | pass | pass |

Each query used a new sequence number. Both bulk endpoint DATA toggles were
retained across queries. The last IN descriptor had 54 residual bytes from
a 64-byte buffer, matching a 10-byte `RDR_to_PC_SlotStatus` reply.
The reader advertised a maximum CCID message size of 522 bytes. That is a
descriptor value; this test exchanged only the small slot-status messages.

The reader's response says no card is present. No card activation, RF polling,
ATR, APDU, PIN, signature, identity document, or card-data operation was tested.
The vendor-specific interface remains unused. The interrupt-IN endpoint was
identified, but this probe uses only EP0 and the two bulk endpoints.

## Firmware / retained evidence

Build command: `NIHOS_NATIVE_USB=1 sh tools/build-native.sh device integer`.
The image audit passed SRAM runtime / bounded Flash tables / known ROM ABI /
no RTOS symbols. The USB host state machine, DMA, enumeration and CCID logic
are Zig; the GPIO/UTMI boundary uses pinned ESP-IDF LL headers without linking
the SDK runtime or USB Host Library. Stock ESP-IDF bootloader ownership remains.
The native probe is opt-in and runs before CPU1 release; it resets/stops the
controller before continuing ordinary native execution. This is not yet a
scheduled USB service or complete CCID driver.

Final application: 93,296 bytes, SHA-256
`f70c3cd76736aad5ae8f5cfe94ff7ae90ea30bfc0c9bb65e406fc95ccad4e5f5`.
Bootloader / partition table / app were written at `0x2000` / `0x8000` /
`0x10000`; esptool verified all three data hashes. The user waived restoration;
the **native USB-enabled image is left installed**. It scans again on reset.
This image does not initialize the display.

Artifacts, source archive, per-boot JSON, complete raw/reset-filtered logs,
flash log and hash receipt:
`/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-usb-native/`.
The raw first capture contains a partial previous-boot UART record emitted
during reset; it is retained. Validation begins at the fresh ROM banner,
and all three validated streams contain exactly one native boot.
The exploratory `pilot-1.log` is retained and is not one of the three final
qualification runs.

## Other checks and remaining boundaries

- 168 host Zig tests passed, including bounded USB/I2C/CCID failure cases.
- 112 Python checks passed, including rejection of partial USB evidence.
- Formatting, ZLint (zero warnings), ShellCheck and six default RV32 native
  ELF links/image audits passed.
- USB + SDMMC enabled together compiled and passed the ELF audit; this combined
  image was **not** flashed or physically qualified.
- Default builds keep USB disabled. The USB option rejects the rev3/emulator
  profile. No CI run or remote publication was performed.

Physical disconnect, malformed devices, STALL/timeout, overcurrent, cold boot,
other readers, hubs and long-running USB service remain unqualified. Recovery
logic was exercised with host models, which is separate evidence. For next
work, first provide the native service lifetime/hotplug boundary, then qualify
card-present status and explicitly chosen card activation/APDU behavior.

Implementation and commands: [native USB notes](../native-usb.md).
Protocol reference: [USB-IF CCID 1.1](https://www.usb.org/sites/default/files/DWG_Smart-Card_CCID_Rev110.pdf).
