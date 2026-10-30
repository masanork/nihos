# Full Rust application surface with separate owner storage

Date: 2026-10-30. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. RV32IMAC/ILP32 native emulator
execution, still offscreen.

The WAMR owner now reserves a separate 32 KiB surface segment in its PSRAM
lease. The C runner borrows this segment only while the owner is active, through
the native-only `nih_wamr_surface_storage` accessor. It attaches the existing
RGB565 adapter to a 160x80 surface with a 324-byte stride. The application no
longer renders into a clipped 64x16 stack buffer.

| Owner segment | Requested bytes |
| --- | ---: |
| Runtime buddy arena | 131,072 |
| Linear-memory buddy arena | 262,144 |
| Two mutable module buffers | 8,192 |
| Private native stack | 65,536 |
| Surface storage | 32,768 |
| Total requested lease | 499,712 (488 KiB) |

These are requested lease segments, not a new measurement of the allocator's
rounded backing reservation or permanently occupied OS memory. Surface pixel
payload is 25,600 bytes; row padding adds 320, and the two immediate guards add
32, for 25,952 used bytes inside the 32 KiB segment. Teardown detaches the
surface, clears the allocation and returns it to the existing owner allocator.

The frame checker uses literal reference bitmap rows for all five Ready and
all seven Pressed glyphs. It checks every one of the 12,800 RGB565 pixels against
the expected background/text composition, plus each padding/guard byte. This
also verifies that switching from Pressed back to the shorter Ready clears
the trailing old glyphs and that rows below the labels receive the background.
Rejected-call checks retain the earlier full-used-frame FNV-1a checksum tests.

The native record now includes surface geometry and capacity:

```text
NIHOS_NATIVE_WAMR_SURFACE checks=0000007f width=000000a0 height=00000050 stride=00000144 bytes=00006540 capacity=00008000
```

The surface mask retains its seven categories but its successful-frame checks
now cover all glyphs and background pixels rather than the first glyph only.
Synthetic state changes, READY-triggered UART input, permission/owner guards,
quit, traps and allocator recovery still pass. Six UART failure cases also
recover owners, surface and both arenas with exact expected counters.

Because the checksum/pixel tests now visit a full surface, the receive-loop
cycle budget increases from 12,000,000 to 64,000,000. The 16-byte dispatch and
three-frame acceptance limits remain unchanged. This budget includes synchronous
rendering/validation work; it is not a physical input latency claim.

Observed private-stack high-water falls from 25,740 to 23,692 bytes while the
requested lease grows from 456 to 488 KiB. Requested runtime/linear peaks remain
19,737/65,536 bytes. Normal execution reports 17 accepted imports, two instance
lifecycles, complete arena recovery, the three 100-round SMP markers, 300-round
soak and integer completion.

The audit reports 252,912 Flash text bytes, 36,075 read-only bytes and zero
undefined symbols. Rust Wasm and signed packages retain their prior hashes.
Canonical ELF SHA-256:
`83a1e57960457333911c3455cf109133d8784bfe5c2fe40a4593d24b2b64acce`.
Merged flash SHA-256:
`8d9e50acd2a173ef309e3212642c656ccb41c0270349ba419be6fb11db325d9f`.

Retained [normal log](evidence/2026-10-30-wamr-native-full-surface/emulator.log),
[UART matrix](evidence/2026-10-30-wamr-native-full-surface/uart-matrix.json),
[build log](evidence/2026-10-30-wamr-native-full-surface/build.log),
[image audit](evidence/2026-10-30-wamr-native-full-surface/image-audit-wamr.json),
[candidate hashes](evidence/2026-10-30-wamr-native-full-surface/candidate-sha256.txt),
and [source hashes](evidence/2026-10-30-wamr-native-full-surface/source-sha256.txt)
bind the candidate. Each negative UART log and stderr are retained alongside
the manifest. Run through `probes/wamr-native/run-emulator.sh`.

This establishes the app's complete logical surface and separates its storage
from the native call stack. Native pointers remain trusted and CPU0 ownership
is exclusive. Display composition, cache publication/scanout, physical input,
multi-application surfaces and physical Tab5 validation remain later work.
