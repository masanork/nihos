# Tab5 native PIN-free JPKI certificate serial / retry-count qualification

Date: 2026-10-26. Firmware source: `697857e`, branch
`codex/tab5-usb-native`, isolated worktree `/private/tmp/nihos-usb-scan`.
The user placed a My Number Card on the attached PaSoRi and authorized
PIN-free authentication-certificate serial / remaining-retry reads, referencing
`~/repo/civ`. No PIN was provided or requested. Main and other dirty worktrees
were not modified.

## Qualified physical observations

Three powered USB-RTS-reset boots of the same final application passed the
strict `usb,jpki` checker. These are not whole-device cold power-on tests.

| Observation | Boot 1 | Boot 2 | Boot 3 |
| --- | --- | --- | --- |
| PaSoRi VID:PID | `054c:0dc9` | same | same |
| Card activation / ATR | active / 13 bytes | same | same |
| Card APDUs | 7 | 7 | 7 |
| Authentication PIN retries before read | 3 | 3 | 3 |
| Authentication PIN retries after read | 3 | 3 | 3 |
| Retry status word | `63c3` | `63c3` | `63c3` |
| Certificate serial | 4 bytes | same value | same value |
| PIN data sent / rejected requests | 0 / 0 | 0 / 0 | 0 / 0 |
| Requested card power-off | success | success | success |
| Subsequent native dual-core rounds | 300 | 300 | 300 |
| Lifecycle, IPI/WFI and owned memory checker | pass | pass | pass |

The requested serial value is retained in private raw logs and was reported
directly to the user. This repository note does not publish that value.
The value is the X.509 serial from the authentication certificate EF, not the
reader serial or card UID. Only a 64-byte certificate prefix was read. This
does not validate the certificate's signature, chain or validity period.

## PIN boundary and reference

The fixed sequence is JPKI SELECT → PIN EF SELECT → exact four-byte
`00 20 00 80` retry query → certificate EF SELECT → 64-byte READ BINARY →
PIN EF SELECT → the same retry query. The data-free VERIFY requests expose
`63c3`; the before/after count remained 3 in every qualified capture.

The transport boundary only admits those exact five APDU forms plus empty
CCID power-on/off messages. It rejects PIN-bearing VERIFY, secure PIN entry,
password modification/reset, arbitrary APDUs, and escape bypasses. There is
no PIN input or automatic PIN-bearing fallback. The code cannot send a guessed
PIN through this diagnostic. If the initial counter is blocked, it stops.

APDU reference: user's read-only civ commit
`54a843e656513930df60bbc20d752ff3289e7078`, `src/jpki.rs` and
`crates/civ-card/src/apdu.rs`. That repository was not changed.
Implementation/commands: [native JPKI notes](../native-jpki.md).

## Retained unsuccessful attempts and corrections

1. `standard/`: immediately after USB configuration, the reader reported
   absent and PowerOn returned no ATR. No card APDU was sent.
2. `delay/`: adding a two-second post-configuration settle produced a successful
   seven-APDU read, with the count 3 before/after. This exploratory image is
   retained independently from the final qualified image.
3. `final/` and `retry-current/`: after a different device task had finished,
   EP0 SETUP failed with host-channel interrupt `0x1002`, before VID/PID or any
   card APDU. The strict checker rejected both captures. No JPKI operation ran.
4. `powercycle-pilot/`: commanding only USB5V_EN off for 250 ms, then on with a
   100 ms settle, restored enumeration and the PIN-free read. The final boot
   probe now uses this sequence, preserving all other expander bits.

The failed attempts are retained; this recovery does not identify the root
cause or measure actual rail discharge. The user kept the same card on the
reader. No physical card removal/replacement test was performed.

A concurrent storage qualification briefly owned the serial port. It was
allowed to finish and release its own reservation; it was not terminated.
Final installation, preverify, all three captures and postverify then used
one exclusive serial descriptor, preventing another cooperative device tool
from interleaving a flash during qualification.

## Firmware and checks

- Final application: 99,264 bytes, SHA-256
  `8794258cdf440b661f0f237e04ef40419a58875f68bac672ec5f43e0e2d695f8`.
- Build: `NIHOS_NATIVE_USB=1 NIHOS_NATIVE_JPKI=1 sh tools/build-native.sh device integer`.
- Device: ESP32-P4 rev1.3, `/dev/cu.usbmodem101`, USB Serial/JTAG.
- Bootloader, partition table, app at `0x2000`, `0x8000`, `0x10000` were each
  verified before and after capture against the retained artifacts.
- The image audit passed SRAM runtime / known ROM ABI / no RTOS symbols.
  Stock ESP-IDF loader remains; the application owns native USB/card logic.
- 173 host Zig tests and 113 Python checks passed. Formatting, ZLint (zero
  warnings), ShellCheck, and six default RV32 ELF/image audits passed.
- No CI run, remote publication, or merge into main was performed.

Private evidence root:
`/Users/masanork/Documents/Codex/2026-10-26/nihos-tab5-jpki-pinfree/`.
`qualified/` contains the three accepted raw/reset-filtered logs, JSON results,
installed artifacts, pre/post verification and exclusive-lease completion.
The root also retains source archives, unsuccessful captures and check logs.

At the end of qualification the native PIN-free diagnostic was installed.
It reruns on reset and does not initialize the display. Further concurrent
device tasks may replace the firmware; installed state is a point-in-time
observation. APDU signing/authentication, PIN entry, protected personal data,
other readers/cards, long-running service and physical failure recovery remain
outside this qualification.
