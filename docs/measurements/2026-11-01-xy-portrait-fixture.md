# xy portrait workspace: bounded Tab5 checkpoint

Source commit `3f8c492bd5befd398bd57ec68bc2287d29304d2d` provides an explicit
portrait xy fixture. The tested device image used `xy_workspace=true`,
`xy_trace=true`, `xy_portrait=true` and `keyboard_i2c=false`. This forcibly
selects portrait and disables the physical keyboard driver; it is not an
automatic keyboard detection test. The candidate application SHA-256 was
`e568f939c9a28db5ccb51620b95e3ffcaac186f8ae294cff12b1ba323c75a53f`.

The foreground renderer supports portrait Home, document, reader, contents,
settings, card and SICP lessons. The fixture converts the touch service's
landscape coordinates back to physical portrait coordinates before dispatch.
Host tests cover Home/document and SICP navigation, keyboard layout and input,
drag-out/back rejection, portrait page continuity and ruby boundaries in
both writing axes. Normal and portrait device image audits passed.

The physical checkpoint acquired the shared writer lock and exclusive serial
access, verified the target identity/security state, backed up and verified
the three Flash regions to be modified, installed the frozen candidate, and
verified candidate bytes before and after capture. It recorded a warm-reset xy
Home, then sent `n` by serial to select the document. The following trace
reported document screen 0, renderer frame 2, failed 0 and peak foreground
render stack use `0x10130` bytes. After the test, all modified regions were
restored and verified. No SD writes were performed; private raw logs and Flash
backups remain outside the repository.

[Sanitized trace](evidence/2026-11-01-xy-portrait-fixture/capture.log) and
[candidate and restore receipt](evidence/2026-11-01-xy-portrait-fixture/result.json)
retain this bounded evidence. The log establishes execution of the forced
portrait rendering path, not the displayed pixel orientation or physical touch
correctness. Optical review, real touches including keyboard gestures,
keyboard-present versus confirmed-absent startup, automatic orientation,
cold power cycling and a post-restoration boot remain unverified. This was not
a production installation or a test of the normal keyboard detection policy.
