# Host language probe baseline

- Date: 2026-10-25
- Evidence: host-only; not a Tab5 performance result
- Host: Apple silicon macOS
- Workload: 4,096-byte bounded ring and FNV-1a checksum through one C ABI

## Toolchains

- C: Apple clang 21.0.0
- Zig: 0.17.0, `-Osmall`
- Rust: 1.98.1, `opt-level = "s"`, LTO, `panic = "abort"`

All three implementations returned:

```text
ok abi=1 checksum=52abebb5 processed=4080 rejected=16
```

## Linked host executable text

| Implementation | Mach-O `__text` bytes |
| --- | ---: |
| C | 640 |
| Zig | 584 |
| Rust | 624 |

The complete executables were each 33,768 bytes because Mach-O page and
segment alignment dominates at this scale. The section value is more useful
for this probe, but it still includes the common C harness.

This result only establishes that the Zig C ABI and safety choices do not
create an immediate code-size regression in a tiny host workload. It does not
predict ESP32-P4 interrupt latency, stack use, DMA behavior, or Quake speed.

The Zig root module was also compiled successfully as a 32-bit RISC-V
freestanding relocatable object with the `m+a+c+f+zicsr+zifencei` feature set.
The resulting ELF used the RVC and single-float ABI. Linking against ESP-IDF
and running on revision 1.3 Tab5 hardware remain separate gates.
