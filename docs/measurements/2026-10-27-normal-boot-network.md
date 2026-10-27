# Normal boot with factory Hosted networking

2026-10-27. This opt-in integration keeps normal display, input and both native
schedulers running while CPU0 acquires IPv4 and services link-local IPv6.
See [ADR 0045](../adr/0045-normal-boot-network-integration.md) for its bounded
lifetime and ownership contract.

The subsequent [lease-lifecycle checkpoint](2026-10-27-network-lease-lifecycle.md)
removes the fixed session limit in source and retains separate physical gates.

## Reproduce the private build

```sh
NIHOS_NATIVE_NETWORK=1 \
NIHOS_NATIVE_CONSOLE=1 NIHOS_NATIVE_CONSOLE_LIVE=1 \
NIHOS_NATIVE_DISPLAY=2 NIHOS_NATIVE_PSRAM_200=1 \
NIHOS_NATIVE_KEYBOARD_I2C=1 \
NIHOS_C6_WIFI_CONFIG=/path/to/private-valid-wifi.json \
sh tools/build-native.sh device
```

The JSON must be mode 0600. The output directory is
`build/native-device-network/`; its configuration and application contain
credentials and stay local. The normal image auditor is unchanged.
`network-receipt.json` binds source/artifact hashes; it does not claim execution.
Only the factory application at `0x10000` is replaced for this measurement.
The C6 firmware, P4 bootloader/partition table and SD are not flashed.

## Failures retained before the final candidate

- The initial combined link failed the 48 KiB SRAM heap floor. CPU-only state
  moved to PSRAM and the integrated root adopted size optimization; DMA buffers
  remained in SRAM. The floor was not reduced.
- Attempt 01 (`15ab021e…`) stopped at `external memory prepare`: the normal
  heap whitelist rejected shrinking its known full-capacity range. The new
  state was relocated into the unused display lease tail, with a compile-time
  overlap/overflow check. The whitelist was not broadened. Its log remains in
  private `build/wifi-device/integrated-01/run-01.log`.

## Scope

Serial records can establish scanout/IRQ progress and accepted diagnostic
input; optical display quality requires separate observation. Injected serial
controls do not prove a physical key press. The integrated application retires
networking after 120 seconds, preserving normal UI/scheduler operation.
SLAAC/global IPv6, DHCP renewal, reconnection, microSD coexistence, application
sockets, C6 TCP/IP/BLE offload and cold power-cycle operation remain open.

## Final physical candidate and result

P4 rev1.3, 32 MiB PSRAM, existing factory C6 Hosted firmware. Attempt 03 ran
132 seconds after a verified application write and USB reset. This is a warm
reset observation, not a cold power-cycle qualification. The full existing
normal-boot core/memory/display checker passed without changes.

| Observation | Result |
| --- | --- |
| IPv4 DHCP | `10.193.127.151/24` |
| IPv6 link-local peer target | `fe80::9aa3:16ff:feb6:a4ec` |
| Early Mac Echo | 10 sent / 10 replies; RTT min/avg/max 12.390/24.378/49.459 ms |
| Late Mac Echo, after initial acquisition ended | 10 sent / 10 replies; RTT 13.393/28.353/90.173 ms |
| Integrated inbound Echo count | 20; continued increasing in station `done` phase |
| Scanout frame counter | 32 → 7,832 |
| Scheduler timer counters | Both 15 → 13,020 |
| Serial display controls | 3 accepted at 30/70/100 seconds |
| Keyboard | Initialization passed; no physical key press in this run |
| Network retirement | At the 120-second bound; IPv4/link-local state cleared |
| UI/scheduler after retirement | Continued through two more 5-second records |
| Maximum measured network poll | 6,963 us, includes initial enumeration |
| Application size / internal heap | 150,624 / 57,344 bytes |

The maximum poll is an observed sample, not a worst-case bound or IRQ latency.
No packet loss occurred in these two short ping samples. Attempt 02 also had
20/20 replies; its early RTT reached 872.156 ms, so this does not establish a
long-running latency guarantee. Both logs remain retained. The final build's
250 source-snapshot hashes and all artifact hashes matched the receipt.

Exact final candidate and logs:

- bin: `052faaf98de7c24dbc5501acf6e7ead43806d7ed14d67001325bb8ed842c61f8`
- ELF: `0193af2e09f30bb104da10a4c6811883f22733fbfc7cd9ea01a01c4da8d6ee14`
- `run-03.log`: `e1b1ff656c7a178836a4b13e51f2a0afe480267fa5b0c2abe7ab56657761f1d3`
- Early ping: `7b1af6a00ea22726a1bafcc312319fe662c07b392a34972a7dff84264b84af56`
- Late ping: `3f399856d1aed7cc4048e365f2c0a78111f07fa7b8054f1882fee0002969a855`

Private evidence is under `build/wifi-device/integrated-01/`: an immutable
`candidate-03/` snapshot, display checker result, `integration-result-03.json`,
raw serial/ping/write logs and their validation script. The receipt records
`04b6db7` plus integration changes; input hashes bind the later committed files.
The board currently runs this combined application. Networking has retired;
the normal diagnostic UI remains running. Resetting starts another bounded
session using the private configuration embedded in the application.

## Host and build verification

- Debug and ReleaseSafe: 276/276 host tests each. The new regression checks
  post-acquisition Echo, retained TX under backpressure, finite-probe behavior
  and address revocation on disconnect.
- Format, ZLint, shellcheck and RV32 architecture probes passed.
- Image audit tests: 21 normal / 5 standalone C6; six normal native ELF audits
  and the combined physical image audit passed.
- All 8 normal-boot headless emulator cases passed with networking disabled;
  these do not emulate a C6 or qualify the combined physical path.
- Network builds combining microSD, emulator execution or a missing private
  Wi-Fi configuration were rejected before compilation.
