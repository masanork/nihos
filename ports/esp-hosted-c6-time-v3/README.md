# Experimental Tab5 C6 Hosted 3.0.10 overlay

This experimental overlay has been installed once on Tab5 and exercised with
P4 time/RTC, Wi-Fi and BLE. See the [physical record](../../docs/measurements/2026-11-02-hosted3-ota-upgrade.md).
It is not a general release qualification. The 2.13.1 implementation remains in
`../esp-hosted-c6-time/`. A failed C6 image may leave no SDIO OTA route; an
independent recovery path and automatic boot rollback are unverified.

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
and left 175,760 bytes in the nominal slot. This exact candidate was subsequently
installed once through SDIO OTA and reported Hosted 3.0.10 after reboot.
The link map contains the service feature descriptor; the service object's
undefined OTA/flash references are limited to read-only queries.

`src/net/hosted_c6_ota_info.zig` provides a bounded P4 query session and checks
nonce, acknowledgement, deadlines, partition bounds and non-overlap. The
caller must own the stream, choose a fresh nonce, and discard the result on
reset. `sh ports/esp-hosted-c6-time-v3/check-ota-info-wire.sh` verifies the
C-generated fixture consumed by its Zig tests. This is an API and wire test;
the request and decoder also compiled for the P4 RV32 target. A separate
`tools/build-c6-ota-info-probe.sh` builds a P4 diagnostic that performs the
Hosted handshake, reads the standard application descriptor and then makes
this one query. Its stream guard admits only the exact handshake configuration,
version, read-only descriptor and Bluetooth setup, and this CustomRpc;
it rejects OTA Begin, Write, End, Activate and other CustomRpc IDs. It does
not authorize a C6 OTA. A later 3.x physical capture is recorded above; there
is not yet a device UI for the query.
In a [physical negative test](../../docs/measurements/2026-11-01-c6-ota-info-negative.md),
the current 2.13.1 C6 returned `ESP_ERR_NOT_FOUND`; the P4 was restored.
Values are self-reported by the running C6 application; this service was absent
from the 2.13.1 image and did not establish its actual partition layout before
the first update. Neither a reported layout nor a security flag
proves an independent ROM recovery path.
The application descriptor's version, project name and IDF version are
self-reported metadata. The optional ELF hash is not the application binary's
hash or a flash readback, and the 2.13.1 build configuration does not enable
the full descriptor fields. The [physical descriptor and rollback analysis](../../docs/measurements/2026-11-01-c6-app-description.md)
records the reported fields and why they do not prove first-boot rollback.

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

`tools/build-c6-ota-hosted3-simulation-probe.sh` builds a separate, digest-pinned
P4 simulation for the 1,397,104-byte candidate above. It requires a 2.13.1
origin, wraps the physical stream to reject every OTA operation, and switches
to an in-memory responder for the transfer and explicit activation. The same
write-blocking wrapper is used for the post-simulation physical handshake.
This is a simulation even if exercised on Tab5; the C6 is not updated.
The [Tab5 simulation record](../../docs/measurements/2026-11-01-hosted3-ota-simulation.md)
documents a full transfer of the exact candidate against the P4 in-memory
responder and a successful post-simulation 2.13.1 handshake.
`sh ports/esp-hosted-c6-time-v3/test-full-candidate.sh CANDIDATE_BIN`
separately hashes and transfers the exact candidate through the P4's OTA
state machine and in-memory 2.13.1 responder on the host.

`tools/build-c6-ota-hosted3-upgrade-probe.sh` separately builds an actual
update fixture for that same pinned digest. **Unlike the simulation, this
fixture can write the C6 after its one-shot token.** It checks the mapped
candidate digest, requires a 2.13.1 origin, and reports a 3.0.10 version after
activation. One byte-identified build was used for the recorded physical OTA; the fixture
does not independently establish the C6 partition table, bootloader behavior,
or a recovery route. The application
descriptor preflight is a separate diagnostic and is not enforced inside this
update image. A future runner must keep exclusive device ownership across both
checks, verify exact bytes, and restore the P4; an uncertain activation must
not be blindly replayed. `tools/c6_hosted3_upgrade_evidence.py` checks the recorded
capture and explicitly rejects simulation markers; its passing output is a
P4-reported version and transfer, not C6 flash readback.

The clean build from commit `0cd87de93cf57d88e2b102feadb85d1bdbb69086`
produced P4 app SHA-256
`84b4a9926b94c3df031b2c7a2b38b3ec9a16591185bf2b19bc448c1af9f5c716`.
The map audit matched the 1,397,104-byte C6 candidate at `0x40010024` and
passed the P4 SRAM/ROM boundary checks. A previous attempt that combined the
full read-only descriptor diagnostic and updater exceeded the fixture's SRAM
limit; the clean build uses separate diagnostics and does not silently widen
the memory map. A later clean rebuild was [run only to the pre-token gate](../../docs/measurements/2026-11-02-hosted3-updater-preflight.md)
on Tab5; no OTA was started and P4 flash was restored and verified.

`tools/build-c6-ota-hosted3-recovery-probe.sh` builds a separate conditional
3.0.10 -> 2.13.1 recovery fixture, pinned to the previously deployed C6 app
digest `7f036e616df4d4782015caf30f185f7859af115438f394463600d0f8d69995be`.
It requires a 3.0.10 origin and an explicit start token, uses 3.x's explicit
OTA Activate, and checks for a subsequent 2.13.1 version response. This is a
build-only recovery *candidate*: it has not been tested against a 3.x C6, and
can work only while the 3.x application boots and serves Hosted OTA over SDIO.
It is not recovery from a C6 that fails to boot or communicate, and the known
2.13.1 candidate is not a readback of the device's currently installed bytes.
`test-recovery-candidate.sh` checks the exact 2.13.1 binary against the host
in-memory responder; `tools/c6_hosted3_recovery_evidence.py` rejects simulated
or incomplete captures if a future physical recovery is attempted.

The [P4 compatibility trial](../../docs/measurements/2026-11-01-hosted3-p4-legacy.md)
ran a byte-identified P4 image against the previously installed C6 application;
it did not independently read back the C6 version or test the 3.x firmware.

Remaining qualification includes independently validating the partition table,
a full device-generated init frame, cold boot and reconnect behavior, longer
operation, and a tested independent recovery or rollback route.
Do not infer iroh or QUIC operation from a successful clock exchange.
