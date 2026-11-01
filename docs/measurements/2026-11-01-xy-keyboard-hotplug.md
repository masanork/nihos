# xy keyboard hot-plug: bounded Tab5 checkpoint

Source candidate `d2284f9d1310155a800140565962597d65caca5c` retries the Tab5
keyboard probe at 500 ms intervals and requires two matching observations
before changing the confirmed state. Address NACK is absence; other bus errors
preserve the previous state. A transition waits for a touch, VM evaluation,
camera overlay or application display to finish. Reading reflow preserves the
current byte offset and clears old-orientation page boundaries. The normal and
trace device builds passed the image audit; the trace profile retained 49,472
bytes of primary SRAM heap against the 49,152-byte floor.

The test candidate used `xy_trace=true`, `xy_portrait=false`, and
`keyboard_i2c=true`; its application SHA-256 was
`420384e6f63f319f4aebd6a27dc28daee962a19408272e8fcdf89e69864cf58d`.
The test held the shared writer lock and exclusive serial connection, checked
ESP32-P4 identity and security state, verified backups for all modified Flash
regions, installed the frozen candidate and verified its bytes before and
after the observation. The test restored and verified those Flash regions
and made no SD writes. Private full logs and backup contents remain outside the
repository.

The initial probe reported address NACK and portrait. A serial `n` opened the
document; no subsequent serial characters were sent. The user tapped software
`q`, attached the physical keyboard, pressed physical `w`, detached it, and
tapped software `e`. The ordered trace records document hashes of `q`, `qw`,
and `qwe` with unchanged serial input count, and a confirmed transition to
`present=1 portrait=0` followed by `present=0 portrait=1`. The user reported:
「問題なかったよ。まだカナ漢字変換はできないけど、ちゃんと動いてた」。
This is a human observation, separate from the device state trace; no optical
measurement was performed.

[Sanitized event trace](evidence/2026-11-01-xy-keyboard-hotplug/capture.log)
and [candidate and restore receipt](evidence/2026-11-01-xy-keyboard-hotplug/result.json)
record this one attach/detach cycle. It does not qualify repeated hot-plug,
transient fault injection on hardware, every key, multi-touch, reflow during
reading on hardware, cold power cycling, or a post-restoration boot. The native
IME still lacks a bound dictionary provider and preedit/candidate rendering;
this checkpoint does not claim kana-to-kanji conversion. The test image was
restored afterward and was not installed as a release.
