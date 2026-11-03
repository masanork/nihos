# Native short UDP experiment: P4 image audit

On 2026-11-03 JST, clean source commit
`e6c8f2beb198ac498d5ae44394565bb3ae2a516c` was built for the default Tab5
integer/XY/sqld/normal-storage device profile with the C6-owned time/address
profile enabled and IPv6 disabled. The C6 configuration used its saved Wi-Fi
settings. Two builds from the same source were structurally audited:

| Profile | Primary SRAM heap | Native image SHA-256 |
| --- | ---: | --- |
| UDP experiment disabled | 49,600 bytes | `f16caef821a918b68ac44b421e83399a47a4dbe66e9b1807f552d5c4fbf75926` |
| Short UDP experiment enabled | 49,472 bytes | `140fac126c72a1928d511d53a22cd206e9a2276170e61f908e9d718a65020a9f` |

Both retain the 49,152-byte heap floor. The experiment uses the existing
bounded sqld network PSRAM reservation for its UDP owner; the 128-byte primary
SRAM difference is not the total resource cost. The experimental ELF SHA-256
was `fb9330f7f2997598d9088ff9c11c0f11f80b3efae75eaf07c0fc83e2377d3156`.
The image audit and an independent symbol check verified that the retained
foreground UDP helpers are in `.flash.xytext`, with no duplicate symbol in
SRAM. The audit's negative regression also rejects a resident duplicate.

The SDK-free RV32 probe compiles the experimental CPU0 API; no application
calls it in this image. The native short transport admits UDP payloads through
458 bytes and rejects longer packets before submission. C6 routing policy,
address resolution in this runtime path, device execution, shared-SD contention,
long DMA, QUIC and iroh remain unverified. No image was flashed in this build
comparison; hashes do not constitute device evidence.
