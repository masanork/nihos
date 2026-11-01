# xy touch keyboard: bounded Tab5 render checkpoint

Candidate source `24bc1212c9afb62e9c2e795fb966c1c1f88daf69` adds the visible
landscape keyboard and shared touch layout. Host tests and normal device image
audit passed on that source. A separate device build with `xy_trace=true` and
`keyboard_i2c=false` exercised the no-keyboard rendering path. This setting
forces the absent state; it does not establish physical keyboard detection or
hot-plug behavior. The trace candidate application SHA-256 is
`2d716b7fb25bb143039b11b8aa98eedcda15b6d6b6c50df51b27cf96c55de5eb`.

On an ESP32-P4 v1.3 Tab5, the test acquired the shared writer lock and exclusive
serial access, checked the device and security state, backed up and verified
all three Flash regions it would overwrite, installed the frozen bootloader,
partition table and candidate application, and verified the candidate bytes
before and after capture. Afterward all three original regions were restored
and verified by `verify_flash`. The private backup and raw logs remain outside
the repository. The test did not write to SD.

The serial trace records xy Home, followed by a serial `n` selecting the empty
document. The next completed renderer record reports `frames=2`,
`failed=0`, and maximum foreground render stack use `0x15ef0` bytes. With the
forced-absent setting and the document in edit mode, the source's visibility
predicate selects the keyboard. This inference and successful renderer return
do not establish the panel pixels or a touch operation.

[Sanitized trace](evidence/2026-11-01-xy-soft-keyboard/capture.log) and
[candidate/restore receipt](evidence/2026-11-01-xy-soft-keyboard/result.json)
retain the bounded evidence. Optical appearance, actual touch typing, physical
keyboard attachment/detachment, cold power cycle, portrait orientation, and
Japanese IME remain unverified. This experiment restores the pre-test Flash; it
does not establish a post-restoration boot or install a product release.
