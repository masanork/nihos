# xy portrait and IME merge: bounded Tab5 checkpoint

Source candidate `5d325335f85debed46ee0391043d994350cebecc` combines the xy
portrait keyboard work with main's SKK input changes. The device trace image
used `xy_workspace=true`, `xy_trace=true`, `xy_portrait=false`, and
`keyboard_i2c=true`. Application SHA-256:
`131dc1d1e443ac1720d4afb9a30471244ffbb3daa03775372db5e2bfd4f7b487`.

Host tests pass for the combined keyboard and IME path: a touch-key Shift and
romaji sequence initiates SKK composition and selects and commits a candidate
from a mock provider. The actual Tab5 reader preview tests also cover portrait
Home, page continuity, settings, SICP example and lesson controls. The full
host suite and normal and trace device image audits passed on this source.
The native session does not bind a dictionary provider or draw IME preedit or
candidates, so this host mock does not establish usable native kanji selection.

The physical checkpoint acquired exclusive writer/serial ownership, verified
the ESP32-P4 identity and security state, backed up and checked the three Flash
regions to be modified, wrote the frozen candidate, and checked the candidate
bytes before and after capture. A warm boot observed keyboard address NACK,
`keyboard_probe=1` and `portrait=1`. Serial `n` opened the document; serial
Escape, `ime` and `kana` produced six UTF-8 bytes with the FNV-1a of `かな`,
with renderer failure count zero. This is serial input, not physical typing.
The modified Flash regions were restored and verified; no SD writes were made.
Private raw logs and Flash backups remain outside the repository.

[Sanitized trace](evidence/2026-11-01-xy-portrait-ime-merge/capture.log) and
[candidate/restore receipt](evidence/2026-11-01-xy-portrait-ime-merge/result.json)
retain the bounded evidence. Panel orientation and keyboard appearance,
physical touch/key gestures, a keyboard-present boot, cold power cycling,
post-restoration boot and native candidate selection remain unverified. An I2C
NACK was observed; the test did not inspect physical attachment. The image was
restored after the test and is not installed as a production release.
