# Terminal shell checkpoint

The normal device profile starts the bounded shell directly. The host preview
uses the production console grid and JetBrains raster with the neutral palette:
[terminal preview](evidence/2026-10-29-terminal-shell/host-preview.png).
This is a host-rendered image, not a photograph or evidence of device display.

Host tests exercise line insertion and deletion, cursor motion, bounded history,
draft restoration and the keyboard driver's modeled I2C FIFO through HID into
the session. The normal device image build and its SRAM/Flash audit passed; the
normal boot emulator tests cover the headless kernel boot and fault cases, not
this display-backed terminal. Physical input, actual panel legibility and
serial terminal compatibility remain to be checked on this candidate.

An independent warm-reset physical trial of commit `57f0990b615a5f803eb6fce6ee61941617d40119` used application SHA-256 `40d7667414922a0f048f5d118b1415886ed70438e4b47cc3e01eefd8804a2d56`. Flash readback matched; display initialization, Tab5 Keyboard detection and terminal view 1 were reported. Injecting `echo serial-check` over serial returned `serial-check`. The private serial capture SHA-256 is `7815861b14fbce9e3577304451917a5977751b781d8551018cda514dd229cc74`. No physical keyboard text or optical legibility claim follows from this log. Periodic diagnostic records were observed interrupting the serial prompt; serial terminal presentation needs a follow-up fix.
