# ESP-AT controller and C6 SDIO firmware build

- Date: 2026-10-27
- Branch: `feat/c6-network-offload`, extending `c934e28`
- Evidence: host execution, RV32 compile checks, C6 firmware compilation only
- No serial port was opened; no C6/P4 image or OTA selection was changed

## P4-side controller

Added `src/net/at_controller.zig` and `at_commands.zig` on top of the bounded
decoder. A closed typed command set covers version/heap queries, Wi-Fi join,
TCP connect/close/read/send, BLE scan/connect/disconnect/discovery and GATT
writes (including CCCD subscription). Quoted fields escape AT delimiters;
control characters and oversized arguments are rejected before transmission.

The controller completes the ten-command profile before admitting application
requests. It acknowledges partial header/payload writes, preserves deadlines
through zero progress, distinguishes TCP's intermediate OK/prompt from SEND
OK, and supports BLE writes' prompt/final-OK flow. Socket bytes are copied to
staging and committed only after the terminal OK; interleaved BLE data uses
the decoder buffer independently. A timeout, reset, framing/transport error
or cancellation produces one failure and requires fresh-link negotiation.
No ambiguous application operation is automatically replayed.

| Check | Result | Boundary |
| --- | --- | --- |
| Zig Debug host suite | 128/128 passed | Includes 15 new controller/encoder tests |
| Zig ReleaseSafe host suite | 128/128 passed | Host execution |
| Static analysis | Passed, zero ZLint warnings/errors | 55 Zig source/probe files plus existing shell/image checks |
| RV32 compile probe | Passed | Decoder, encoder and controller code generation, not execution |
| Existing native ELF checks | Six audited links passed | No emulator/device run in this task |

Tests exercise partial and zero-progress TX, startup gating, binary payload
ownership, TCP/BLE interleaving, final-response phases, rejection cleanup,
read staging, timeout and reset, stale session identity, partial URC admission,
transport loss/cancellation, deadline overflow and command injection rejection.
See [adapter contract](../../src/net/README.md). Resource-handle tables, native
mailboxes and the actual P4 SDIO driver are still absent.

## C6 firmware

Built the pinned upstream ESP-AT `7c092f9aee793d6dbfae31e7585637baa14fb4ce`
(v4.1.1.0), SDK base `8ad0d3d8f2faab752635bee36070313c47c07a13`, and that
SDK's submodules. The external overlay is `ports/esp32c6-at/sdkconfig.defaults`.
The resolved config enables SDIO (512-byte block), Wi-Fi, TCP/IP, NimBLE and
software coexistence together, with UART AT disabled. MQTT/HTTP/OTA/BluFi AT
registration is disabled. This is a 4 MiB upstream C6 module profile, not a
measurement of the installed module.

Tools: GCC 14.2.0 (`esp-14.2.0_20241119`), Python 3.12.16, CMake 4.4.4,
Ninja 1.13.2. The builder records package versions, resolved sdkconfig,
component lock, source pins, actual SDK changes, tool recipe and binary hashes.
At build time the nihos worktree included uncommitted controller/build work;
the receipt explicitly records `nihos_dirty: true`. Upstream source and SDK
base revisions are separately checked, and SDK changes are retained.

| Image | Bytes | SHA-256 |
| --- | ---: | --- |
| C6 application | 1,691,616 | `9868a13d1e12e6f4ce19d4efd2201be0f7efd27cce73925067d5b1e48ac0ca15` |
| C6 bootloader | 22,128 | `b4acc7411be4cda58d622103eb2ed3d0f32c10d8728ad197885bb02eb2b73bb6` |
| Filled factory image | 4,194,304 | `b51d9edb571d2da092794f0d933354b56715bd10e0b78cdd5e44591aaddb8f77` |

These image lengths are not resident SRAM use, available heap or a throughput
result. After adding the tool-version manifest, a second build of the verified
patched candidate produced the same application hash. This is an incremental
repeat, not proof of a clean reproducible build.

Local artifact root: `build/c6-at/`. `receipt.json` inventories the eight
flash/factory binaries and retained inputs; an independent readback of these
local files confirmed every recorded length/hash. Upstream flash metadata is
included for review, but its printed flash commands were never executed.
See the [build procedure](../../ports/esp32c6-at/README.md).

## Failed attempts and correction

The first configure attempt used an external build/sdkconfig location; upstream
partition generation requires fixed `<source>/build` and `<source>/sdkconfig`
paths and failed. The builder now uses those paths in a dedicated checkout.

During recovery from that attempt, SDK changes were reverted while copied
upstream patch-marker files remained. ESP-AT then skipped required patches.
That build was rejected during post-build source review, before any flash.
Its application hash was
`a41889afe9066da98083e91c0091798197a484965ddc150385c1714470b30b46`;
it is not the candidate above. Its log/config/receipt/app were retained under
`build/c6-at/attempts/unpatched/`.

The marker files were removed and sdkconfig regenerated in the owned SDK
checkout. Both required patches are now checked against their actual applied
content with `git apply --reverse --check`, rather than trusting markers:

- `support_ext_partition.patch`: `098f56d1aecff6f6d82141e0fbb2a7ad9ddb213d07d20103d04421313ef5de1e`
- `dhcp_option_len.patch`: `b5d02db67389e304c36cb341770454b027463212f090a18385ee49ae86781944`

The patched configuration resolves `LWIP_DHCP_OPTIONS_LEN=69` with vendor class
ID disabled. The actual SDK diff and patch source hashes are in the receipt.

## Remaining gates

C6 download/recovery wiring and flash backup, actual module/flash identity,
P4 SDIO/controller arbitration and IRQ/DMA adapter, native service wiring,
socket/BLE generation tables, firmware boot, real TCP/BLE concurrency,
notification loss/latency, SRAM/heap, reset/reconnect, microSD/display
interference, HTTPS trust and BLE HID remain unqualified. The compile result
does not establish any of these physical properties.
