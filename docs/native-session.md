# Native xy workspace and diagnostic launcher

The normal `sh tools/build-native.sh device integer` profile starts xy Home.
Its touch cards open a RAM document, tutorials, Kusamakura, SICP excerpts,
the repository book, and display settings. Books and fonts are bundled in
Flash; SD and network access are not needed for reading. Select `n` to enter
the RAM document. It supports UTF-8 text, grapheme editing, undo and a bounded
Scheme minibuffer; see [the xy overview](../README.md). The I2C Tab5 Keyboard is
enabled by default with the existing US HID mapping; set
`NIHOS_NATIVE_KEYBOARD_I2C=0` to disable it. This does not provide an SD save
operation. The older single-row ASCII editor and terminal-first startup from
PRs #71 and #79 are superseded by this workspace.

## Normal xy input connections

The standard device profile polls the Tab5 I2C keyboard at address `0x6d`
outside interrupts. `Keyboard.poll` supplies bounded HID press events to
`session_input.Hid`, then `diagnostic_ui.sessionKey` calls the shared xy
`scratch.Model.handle`. Serial UTF-8 uses `scratch.Model.feedSerial` and the
same document/controller. The physical-keyboard path is active in xy mode;
it does not depend on entering the diagnostic launcher.

| Input | Normal xy action |
| --- | --- |
| Home: touch, arrows / Enter, `1`–`4`, `n`, `s` | Choose a book, document or settings |
| Document: letters, digits, Shift, Caps Lock | US HID text mapping |
| Document: arrows, Enter, Backspace | Move, newline, delete before cursor |
| Document: Ctrl-D, Ctrl-Z | Delete after cursor, undo |
| Document: Esc, Ctrl-C | Open minibuffer, return Home |
| Reading: touch footer, arrows / Space, `c`, `s`, Esc | Page, contents, settings, Home |
| Ctrl-L | Refresh the current view |
| Document: touch body | Return Home; no touch caret placement |

The minibuffer evaluates Scheme or opens `help`, `log`, `mem` and `tasks`.
Those system views are read-only. USB/Bluetooth keyboard adapters, native IME,
SD saving and startup restoration of RAM text/settings are not connected by
this profile. Japanese display and serial UTF-8 input are separate from IME.
The [Tab5 reader report](measurements/2026-10-31-xy-tab5-reader.md) and
[sideways Latin report](measurements/2026-10-31-xy-sideways-latin.md) record
the reader candidates. The earlier
[boot/input physical report](measurements/2026-10-31-xy-boot-input.md)
records keyboard and splash validation on its own candidate.

## Diagnostic launcher fallback

The following launcher and shell describe the diagnostic fallback used when
`NIHOS_NATIVE_XY_WORKSPACE=0`, including explicit camera qualification profiles.

The live integer diagnostic profile enters a small launcher after core health
checks complete and the milestone-driven boot graphic reaches its final colour.
The ESP-IDF backend and native qualification profiles retain their existing
behaviour. This work builds on `codex/native-console` (`8cd0076`).

The launcher lists only implemented tools: Shell, Boot log, Memory and Tasks.
Up/Down or 1–4 selects a tool; Enter opens it. Escape opens the shell directly.
During initialisation, Escape still opens boot diagnostics and does not abort a
driver. After handoff, Escape in the log viewer returns to the launcher. Escape
or Ctrl-C in the shell cancels the current input; `exit`, `launcher`, or Ctrl-D
on an empty line returns to the launcher.

The shell implements `shell`, `help`, `clear`, `log`, `mem`, `tasks`, `launcher`
and `exit`. Menu actions and command names share the same dispatch. There are
no executable files, background jobs, pipes, filesystem commands, interpreter,
or external apps in this first version.

Input is ASCII, with a 64-byte command limit, Backspace, Shift, Caps Lock and
Ctrl-L. Characters beyond the limit are ignored. The I2C Tab5 Keyboard uses a
US-style HID-to-ASCII mapping; Japanese input, USB/Bluetooth keyboard adapters,
touch selection and on-screen keyboards are future work. Serial accepts the
same commands and menu navigation, echoes edits, suppresses the LF of CRLF,
and distinguishes standalone Escape (30 ms) from arrow sequences. Arrow keys
in the shell do not yet recall history or move the cursor.

`mem` reports the calling CPU0 owner's SRAM boot arena and reusable PSRAM heap
capacity/free/used bytes. Local interrupts are masked only while copying those
counters; the peer allocator is never read. These figures exclude stacks,
display reservations and other owners. `tasks` shows the existing individually
published per-hart tick/switch/call counters. It is not a process list or an
atomic snapshot across cores. Normal boot currently runs bootstrap/idle contexts
with no user apps, so zero worker activity is expected.

The shell retains 2,048 bytes of output in a separate ring. Its state is placed
in the unused tail of the existing display reservation, with alignment and size
checks; there is no new framebuffer or general heap allocation. Shell output
does not overwrite the boot journal. Diagnostic logging continues independently.
A fatal CPU0 path switches back to the diagnostic journal, bypassing the shell.
All keyboard, serial command handling, drawing and I2C work runs outside IRQs.

Serial evidence uses `NIHOS_NATIVE_SESSION_READY` (view 0 = launcher, line/history
capacities) and `NIHOS_NATIVE_SESSION_VIEW` (from/to; 1 = shell, 2 = boot log).
The existing health, READY and final splash records precede the session record.

## Build and verification

With the pinned Zig toolchain, ESP-IDF v5.4.4 headers and generated device loader
configuration available as described in [native boot](native-boot.md):

```sh
NIHOS_NATIVE_DISPLAY=2 NIHOS_NATIVE_PSRAM_200=1 \
NIHOS_NATIVE_CONSOLE=1 NIHOS_NATIVE_CONSOLE_LIVE=1 \
NIHOS_NATIVE_KEYBOARD_I2C=1 \
sh tools/build-native-elf.sh device build/launcher-device integer
python3 tools/check-native-image.py build/launcher-device/nihos-native.elf \
  --elf-only build/launcher-device/image-audit.json integer device
```

`tools/build-native.sh device` uses the same flags to package a Flash candidate.
Building or auditing an ELF does not install it on hardware.

```sh
.tools/zig-0.17.0/zig build test
.tools/zig-0.17.0/zig build test -Doptimize=ReleaseSafe
sh tools/run-static-analysis.sh
python3 -m unittest discover -s tools -p '*test.py'
python3 tools/run-native-boot-smoke.py
python3 tools/console/preview.py --session launcher
python3 tools/console/preview.py --session shell
```

Host tests exercise menu/command round trips, long input, editing/cancellation,
unknown commands, history wrap, display geometry, HID mapping and serial CRLF/
escape handling. The previews use the production grid and raster. Headless
emulator cases cover existing core boot and fault paths; they do not execute
the display-backed launcher or qualify physical input/display operation.

Physical qualification remains pending for this candidate: boot to the launcher,
use the real keyboard to enter the shell, run each command, return with `exit`,
re-enter the launcher/log viewer repeatedly, confirm serial input/output, and
check that boot health, display errors and stack guards remain valid. Do not
reuse the base branch's physical receipt as evidence for this image.

The completed host/build checks and exact artifact hashes are recorded in the
[2026-10-27 checkpoint](measurements/2026-10-27-native-launcher-host.md).
