# Native terminal and shell

The normal device boot enters a terminal with a `nihos>` prompt after the boot
health checks and splash. The I2C Tab5 Keyboard is enabled by default; set
`NIHOS_NATIVE_KEYBOARD_I2C=0` to disable it. Serial input is also supported.
The standard device build uses the larger JetBrains Mono console face and a
neutral palette; `NIHOS_NATIVE_CONSOLE_FONT` and `NIHOS_NATIVE_CONSOLE_PALETTE`
remain configurable.

The shell offers `help`, `clear`, `echo`, `log`, `mem`, `tasks`, and `edit`.
`tools` opens the optional tools menu; `launcher` and `exit` also open it for
compatibility. `echo` prints its literal arguments; quoting, pipes, program
execution and shell expansion are not implemented. `log` and `edit` return to
the terminal with Escape. The editor is a one-line ASCII buffer in RAM; it does
not save to the device.

Input is printable ASCII, with a 64-byte command limit. Left/Right edit within
the current line; Up/Down navigate the last four distinct consecutive commands
and restore the unfinished draft. Backspace, Shift, Caps Lock, Ctrl-C and
Ctrl-L are supported. Serial redraw uses ANSI erase-line and cursor-left
sequences. The keyboard uses the existing US-style HID mapping; Japanese input,
USB/Bluetooth keyboard adapters and on-screen keyboards are not implemented.
At an empty serial prompt, a leading colon remains reserved for the existing
`:storage`, `:read`, and device diagnostic commands. A colon within a shell
command or editor text is ordinary input. During initialisation, Escape opens
boot diagnostics and does not abort a driver.

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

Serial evidence uses `NIHOS_NATIVE_SESSION_READY` (view 1 = terminal, line/output
capacities) and `NIHOS_NATIVE_SESSION_VIEW` (from/to; 0 = tools, 1 = terminal,
2 = boot log, 3 = editor).
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

Physical qualification remains pending for this candidate: boot to the terminal,
use the real keyboard to edit and recall commands, open the editor and return,
and check serial input/output and boot health. Existing physical results for
other source heads do not qualify this image.

While a terminal input line is active, normal typed diagnostic records clear the
serial input line before the record and redraw the unfinished line and cursor
after it. This preserves periodic diagnostic records without embedding them in
the user's command. Normal Wi-Fi and storage notifications use the same framing. Other unstructured
serial output and output from another CPU remain outside this protection; the
terminal does not yet implement a general VT/ANSI parser.
