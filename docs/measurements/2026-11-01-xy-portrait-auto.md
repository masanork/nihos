# xy automatic portrait: bounded Tab5 checkpoint

The source candidate `1c5d7148f1e5e239dc0623978f4faedf6c0d6d06` selects the xy
session orientation at startup from the Tab5 I2C keyboard probe. A confirmed
address NACK selects portrait; a successful probe selects landscape; disabled
or failed probing selects landscape. The choice stays fixed for the session.
The touch keyboard remains available when the physical keyboard is unavailable.
This checkpoint does not qualify hot-plug or automatic retry.

The device candidate had `xy_workspace=true`, `xy_trace=true`,
`xy_portrait=false` and `keyboard_i2c=true`: the forced-portrait fixture was
not used. Its application SHA-256 was
`c7907ca53f00dd1848d61458730edbac7c08384721894cf8fdf9d78878d22526`.
Host tests covered the probe policy, both orientations' geometry, document
and lesson input, drag rejection and page continuity; the ordinary and trace
device images passed their image audits.

With shared writer lock and exclusive serial ownership, the test checked the
ESP32-P4 identity and security state, backed up and verified the three Flash
regions to be modified, installed the frozen candidate and verified candidate
bytes before and after capture. The warm-reset boot reported keyboard status 2
(address NACK), probe 1 (absent) and portrait 1. A serial `n` selected the
document; the trace then reported screen 0, renderer frame 2, failed 0 and
peak foreground render stack use `0x10130` bytes. All modified regions were
restored and verified; no SD write was performed. Private backups and raw logs
remain outside the repository.

The [sanitized trace](evidence/2026-11-01-xy-portrait-auto/capture.log) and
[candidate and restore receipt](evidence/2026-11-01-xy-portrait-auto/result.json)
show the observed absent-probe boot only. They do not establish a physically
unplugged accessory, a keyboard-present boot, screen pixels, physical typing,
hot-plug, cold power cycling or post-restoration boot. Optical and physical
touch checks remain required before treating the UI as device-qualified.
