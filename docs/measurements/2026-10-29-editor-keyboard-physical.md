# Tab5 editor keyboard trial, 2026-10-29

The device trial used source head `9fed78af18f92864e22dcd219c500cff226f9b1e` with `NIHOS_NATIVE_KEYBOARD_I2C=1` in the normal device integer profile. The application image SHA-256 was `34d5ebc1a7fcf81f08d770519a843c0faed526b911ea58c6bc0ac14138bc1b78`; the Flash readback verification of that image succeeded. The shared board lock and serial exclusion were held during the write and capture. The user had authorized overwriting without a backup; the partition table was verified, not rewritten.

After a warm USB reset, the serial log recorded keyboard status 1, firmware 1, mode 1, five I2C transactions, sources 3, launcher readiness, and a launcher-to-editor view transition. No serial keys were sent by the capture script. The operator reported that typing and cursor editing worked. The raw serial capture remains private; its SHA-256 is `15af8efd92e3ec28547bffbe22486120507cd38f4fdf3b532d85a2507e3d5966`.

The text contents are not recorded in the log, so the editing result is operator-reported rather than independently reconstructed. This is a warm-reset trial of the identified candidate, not a cold-boot test, storage persistence test, IME test, or qualification of later image bytes. The editor remains a single unsaved ASCII row.
