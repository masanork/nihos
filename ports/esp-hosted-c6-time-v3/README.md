# Experimental Tab5 C6 Hosted 3.0.10 overlay

This is a build candidate, not a qualified device update. The 2.13.1 C6
implementation remains in `../esp-hosted-c6-time/`. Do not install this image
until the running C6 partition layout and a recovery path have been verified,
the P4 dual-version image has been validated, and the exact OTA candidate has
been identified. A failed C6 image may leave no SDIO OTA route.

The overlay targets ESP-Hosted commit `4e029441bc0322b368c19767d91d84c6de197ba1`
(3.0.10) and ESP-IDF 5.5.6 commit `880a203ae603d08a94d06aa01e0d6761958e5e9e`.
Initialize the pinned `common/serializers/third_party/msg_codec/protobuf-c`
submodule. Apply `python3 ports/esp-hosted-c6-time-v3/apply.py HOSTED_CHECKOUT`
to a clean checkout; the example component override requires the checkout
directory to be named `esp_hosted`. Use the included `sdkconfig.idf556` as a
copy in the build directory, not as a mutable file in this repository. Build
the `examples/wifi/sta/cp` project for `esp32c6` using ESP-IDF 5.5.6.

The overlay uses SDIO streaming rather than the new default software
aggregation, the existing Tab5 partition CSV, network split, peer data, and
Bluetooth controller. It disables automatic Wi-Fi connection on station
start so that P4 controls connection timing. `app_main` initializes NVS and
the event loop before `eh_cp_init`. The service registers as an auto-init
feature after peer data, rather than racing the asynchronous core startup.
Its clock wire format is unchanged from 2.13.1. The stock example erases NVS
when IDF reports no free pages or an incompatible version; this behavior must
be considered in the physical migration plan.

The earlier time-only build produced a 1,395,264-byte app (SHA-256
`c76f2127d2dc182893c3f15b8bbce6cfc9f36f9653c76fdcd7989cf8ed65bb9b`),
leaving 177,600 bytes in a 1,572,864-byte OTA slot. The generated partition
table SHA-256 was
`0241fa0d2e573dee86756e39fb4181e61ff7218087619cab565b602df55954d6`,
matching the previously reconstructed table. This is not a readback of the
installed device's partition table. The ELF map contains the time-service
auto-init descriptor. The build is evidence of compilation and slot sizing only;
it has not been flashed or exercised on C6.

The newer candidate also adds a bounded, read-only CustomRpc snapshot for the
running, configured boot, and next OTA partitions; flash size; running OTA
image state if available; and secure-boot/flash-encryption flags. It runs the
query in a separate worker with a one-entry queue and reports results with the
request nonce. It does not expose flash contents, inspect bootloader rollback
configuration, or modify partitions. The fields are queried sequentially and
are not an atomic snapshot; the caller must exclude concurrent OTA and reset.
A full queue drops requests, so the P4
must time out. A successful 3.x build with this addition produced 1,397,104
bytes, SHA-256
`04bd14faf943453ccf39075bc61456463b3f362643a3a63dab0f82a53f4dc8fe`,
and left 175,760 bytes in the nominal slot. This candidate is also unflashed.
The link map contains the service feature descriptor; the service object's
undefined OTA/flash references are limited to read-only queries.

`src/net/hosted_c6_ota_info.zig` provides a bounded P4 query session and checks
nonce, acknowledgement, deadlines, partition bounds and non-overlap. The
caller must own the stream, choose a fresh nonce, and discard the result on
reset. `sh ports/esp-hosted-c6-time-v3/check-ota-info-wire.sh` verifies the
C-generated fixture consumed by its Zig tests. This is an API and wire test;
the request and decoder also compiled for the P4 RV32 target. A separate
`tools/build-c6-ota-info-probe.sh` builds a P4 diagnostic that performs the
Hosted handshake and this one query. Its stream guard admits only the exact
handshake configuration, version and Bluetooth setup, and this CustomRpc;
it rejects OTA Begin, Write, End, Activate and other CustomRpc IDs. It does
not authorize a C6 OTA. There is not yet a device UI or a 3.x physical capture.
Values are
self-reported by the running C6 application; this service is absent from the
currently installed 2.13.1 image and cannot establish its actual partition
layout before the first update. Neither a reported layout nor a security flag
proves an independent ROM recovery path.

The P4 recognizes the 3.0.10 MCU RPC-v2 advertisement, echoes it only when
advertised, rejects unsupported SDIO modes and accepts the time path only for
the known version with its required TLVs. A matching version does not prove a
custom time service is present: absent service must still time out safely.
Synthetic host tests do not establish device interoperability. The previous
physical 2.13.1 OTA and RTC results are not evidence for this 3.x candidate.

`sh ports/esp-hosted-c6-time-v3/check-init-fixture.sh HOSTED_CHECKOUT`
rebuilds `src/net/fixtures/hosted-3.0.10-init.bin` using the pinned upstream
TLV builder and checks its bytes. Its capability bits and 7-block buffer sizes
are representative inputs, not observations from a running C6. The P4 host
test parses the resulting complete initialization payload.

`sh ports/esp-hosted-c6-time-v3/check-ota-reference.sh HOSTED_CHECKOUT`
generates Begin, Write, End and Activate requests with the upstream 3.0.10
protobuf-c definitions and checks the P4's independent test vectors. The P4
OTA session supports 3.0.10 only via explicit `allow_310` opt-in and matching
RPC-v2/streaming advertisements. Successful Activate response means accepted,
not that the next firmware booted or that a recovery route is available.

The [P4 compatibility trial](../../docs/measurements/2026-11-01-hosted3-p4-legacy.md)
ran a byte-identified P4 image against the previously installed C6 application;
it did not independently read back the C6 version or test the 3.x firmware.

Remaining qualification: validate a full device-generated
init frame, the actual OTA/partition and recovery behavior, then the 3.x boot,
Wi-Fi, BLE, split address, time/RTC, reconnect, and a tested rollback route.
Do not infer iroh or QUIC operation from a successful clock exchange.
