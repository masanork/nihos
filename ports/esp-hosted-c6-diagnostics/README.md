# Experimental Hosted 1.4.1 C6 diagnostics

This is a source overlay for Espressif's `esp_hosted` 1.4.1 slave example,
not a replacement included in the factory firmware profile. It appends optional
protobuf fields to the existing GetCoprocessorFwVersion response:

- 100: schema version, currently 1
- 101: time since C6 boot, whole seconds (32-bit wrap after approximately 136 years)
- 102: free heap bytes at response construction time

The normal 1.4.1 version fields are unchanged. A factory response has no
extension; old protobuf clients ignore it. Allocation failure leaves the
normal response intact. The P4 station parses a valid extension at its usual
version query and retains a snapshot in `Client.c6_diagnostics`; this does not
add a periodic polling or user-interface path. Free heap is a momentary total,
not peak memory or guaranteed contiguous allocation. The unauthenticated
local extension is not proof of firmware identity or flash contents.

## Build-only candidate

Use the Espressif 1.4.1 slave example archive SHA-256
`fea3ab86d09a852a13a0a5abcf346489fcebd4b7fe6c34192bc59cdd223b2dc6`.
Unpack it to a fresh directory and apply from that directory:

```sh
patch -p1 < /path/to/nihos/ports/esp-hosted-c6-diagnostics/hosted-141-diagnostics.patch
cp /path/to/nihos/ports/esp-hosted-c6-diagnostics/nihos_c6_diagnostics.[ch] slave/main/
```

Build with ESP-IDF commit `f420609c332fbd2d2f7f188c6579d046c9560e42`,
`IDF_TARGET=esp32c6`, example C6 defaults and the installed matching tools.
The 2026-11-01 build uses IDF_COMPONENT_MANAGER=0 and the same sdkconfig as the
baseline (SHA-256 `7cd3b16db4d1d98fc5ab3f2564ec89104f80a4014c17972cf7e0feec8c046228`).
Its app image is 1,079,120 bytes (+272 from that baseline), SHA-256
`0ab00183efb3149b568d0968877f1a7718f7c79817748a8e5c0417957cbf5e3b`;
checksum and validation hash pass esptool image_info. The generated partition
table SHA-256 is `0241fa0d2e573dee86756e39fb4181e61ff7218087619cab565b602df55954d6`,
identical to the published M5 image's table. Artifacts and logs are at
`/private/tmp/nihos-c6-diagnostics-build` and
`/private/tmp/nihos-c6-diagnostics-build.log`.
These results do not establish runtime compatibility, actual board layout,
secure-boot policy, OTA recovery, Wi-Fi/BLE coexistence, or hardware behavior.
The actual device was not flashed. The candidate is not yet wired into a P4
OTA execution path.

## Host wire test

Pass the extracted 1.4.1 `slave` directory to `run-host-test.sh`; it compiles
and packs the actual protobuf-c response with the extension, checks exact bytes,
and frees it through the upstream response cleanup function. NIHOS additionally
tests the diagnostic parser and station path through `zig build test`.
