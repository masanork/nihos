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
