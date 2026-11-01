# Rust Wasm renders into a native RGB565 surface

The later [owner input/frame run](2026-10-30-wamr-native-events.md) adds managed
`0 -> 1 -> 0` dispatch and closed/busy/stopped-owner checks. Its candidate and
eleven-call count supersede this preceding nine-call rendering fixture.

Date: 2026-10-30. Experimental worktree based on
`c0ff17d5ea6802eed4769a5b588da1735dbfbd32`. RV32IMAC/ILP32 execution in the
ESP32-P4 emulator. Offscreen rendering; physical scanout is not exercised.

The native WAMR graphics imports now call the existing
`src/graphics/rust_app_probe.zig` adapter after instance-owner permission and
guest-memory validation. The rectangle import translates RGB through the same
RGB565 surface backend used by the native Rust sample. The text import passes
only the validated guest slice for synchronous rendering; the adapter never
retains it. The native build links the adapter and existing ASCII font into the
WAMR Flash sections. The structural audit checks the four adapter entry points
are in executable Flash.

CPU0 borrows a 64x16 surface with a 132-byte stride (128 pixel bytes plus four
padding bytes per row), surrounded by 16-byte guards. The 2,144-byte guarded
buffer lives on the existing private WAMR stack. No new lease or heap pool is
introduced. The app's 160x80 fill is clipped to the smaller surface, matching
the earlier finite native Rust sample's offscreen geometry.

The emulator requires:

```text
NIHOS_NATIVE_WAMR_OWNER checks=0000000f released=00000001 services=00000001
NIHOS_NATIVE_WAMR_SURFACE checks=0000007f
```

The surface mask records seven checks:

| Bit | Check |
| ---: | --- |
| 1 | Frame checksum unchanged through the four owner/permission denials |
| 2 | `Ready` background 0x1082 and exact 8x8 first-glyph R bitmap |
| 4 | `Pressed` background 0x220c and exact 8x8 first-glyph P bitmap |
| 8 | Injected rectangle-service error leaves frame checksum unchanged |
| 16 | Invalid guest text leaves frame checksum unchanged |
| 32 | Second instance renders the expected Pressed state with intact padding/guards |
| 64 | Adapter detach makes direct drawing return -3; padding/guards remain intact |

Pixel checks use literal reference R/P rows and RGB565 colors independently of
the rendering callback. Unchanged-frame checks use a 32-bit FNV-1a checksum over
pixels, padding and guards. Padding and guards are additionally checked byte by
byte. This verifies the first glyph and background, not every glyph in each
label. Nine accepted host drawing calls, two module lifecycles, invalid-range
trap, bad text, instruction metering and complete buddy-arena recovery still
pass. Three 100-round SMP markers, the 300-round soak marker and integer
completion follow rendering and cleanup.

The owner still borrows 456 KiB total: 128 KiB runtime arena, 256 KiB linear
arena, two 4 KiB module buffers and a 64 KiB private stack. Runtime/linear peaks
remain 19,737/65,536 requested bytes. The observed stack high-water is now
25,708 bytes. Root/trust/install/recovery reports 106,780,692 emulator cycles;
this covers boot admission, not rendering latency or physical-device timing.

The audit reports 251,968 Flash text bytes, 35,947 read-only bytes and zero
undefined symbols. The Rust Wasm and both signed packages retain their prior
hashes. Canonical ELF SHA-256:
`4c1db8029745501dff7facbbe3b630ebb855ea2ed9d0871544a3d00d3293e171`.
Merged flash SHA-256:
`690ff568320b92522cc4afe67955a51b8b66a8bed682c96ceb3e4b9aa64cd1bd`.

Retained [emulator log](evidence/2026-10-30-wamr-native-surface/emulator.log),
[build log](evidence/2026-10-30-wamr-native-surface/build.log),
[image audit](evidence/2026-10-30-wamr-native-surface/image-audit-wamr.json),
[candidate hashes](evidence/2026-10-30-wamr-native-surface/candidate-sha256.txt),
[media hashes](evidence/2026-10-30-wamr-native-surface/boot-media-sha256.txt), and
[source hashes](evidence/2026-10-30-wamr-native-surface/source-sha256.txt)
bind this candidate. The existing emulator runner executes the new checks along
with host crypto/admission/process/crash regressions.

The surface adapter is exclusively attached by this single synchronous CPU0
owner and detached before its stack storage is released. This adds a real
native rendering backend to the Wasm probe, while presentation, display damage
ownership, touch/keyboard events, multiple concurrent application surfaces,
cancellation and physical-device validation retain their existing gates.
