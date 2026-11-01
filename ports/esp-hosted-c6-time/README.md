# Experimental C6 time snapshot

This is an opt-in Hosted 2.13.1 / Network Split experiment, not wired into the
normal NIHOS networking path. The C6 OTA and subsequent P4 probe are recorded
in `docs/measurements/2026-11-01-c6-time-ota-upgrade.md`. A 2.13.1 version
response by itself is not proof of a working time service. One later physical
P4 request reported a synchronized time; see the same measurement. The P4
contract is `src/net/hosted_c6_time.zig`; the experimental station, Network Split and
CustomRpc owner is `src/net/hosted_c6_time_exchange.zig`.

The C6 runs ESP-IDF SNTP against `pool.ntp.org` and a worker returns a snapshot
on CustomRpc. The Hosted RX callback only validates the fixed-size request and
tries a nonblocking, one-entry queue; saturation drops the request and the P4
must time out. The snapshot states whether this C6 boot has observed a sync
callback; if so it includes Unix seconds and elapsed monotonic seconds since the
last callback, saturating at `UINT32_MAX`. Before the first callback, time and
age are zero and marked unavailable. Age is measured at the C6 snapshot, not
at receipt on P4. It increases across loss of network, and no maximum acceptable
age is implied.

**SNTP is unauthenticated.** A sync callback and plausible age do not establish
trust, clock accuracy, reachability, replay resistance, or TLS-validity policy.
P4 must impose its own acceptance and rollback rules. DNS/server failure,
reboot, AP loss, and clock jumps require device tests. The callback means only
that the configured SNTP client reported a synchronization.

A 16-byte request and 32-byte result carry version, P4-generated request ID
and connection generation in little endian. The P4 permits one in-flight request,
rejects stale generations, requires a deadline, and accepts the asynchronous
event even if it arrives before the CustomRpc acknowledgement. The caller must
correlate the acknowledgement, cancel on rejection, expire the request, and
supply a new nonzero generation on *every* C6/transport reset. A successful
transport acknowledgement is not a time result; sending a result is not proof
of its delivery. The ID is not reused during a session after wrap. This is a
local correlation protocol, not authentication.

The existing HTTPS overlay initializes its own SNTP client, so Kconfig forbids
enabling it and this experiment together. `apply.py` expects a disposable
checkout of ESP-Hosted commit `0e8d0e3f0c2723deaf15441200cb4d8c53fea230`
that already has the Network Split and HTTPS integration overlays from the
separate `nihos-iroh-service-contract` experiment. Applying this overlay does
not automatically apply the OTA activation fix. Build with
`CONFIG_NIHOS_HTTPS_SERVICE` disabled and `CONFIG_NIHOS_TIME_SERVICE=y`.
Do not treat this integration as a reusable, source-pinned full build recipe;
the preceding overlays and all sdkconfig settings must be independently
reviewed and recorded. The candidate must not be written until its OTA and
recovery paths have been qualified.

Host checks:

```sh
ports/esp-hosted-c6-time/run-host-test.sh
"$(sh tools/bootstrap-zig.sh)" test src/net/hosted_c6_time_test.zig
```

The C and Zig tests use matching byte vectors. They do not exercise CustomRpc,
Wi-Fi, ESP-IDF SNTP or scheduling on the device. The ESP-IDF build, if present,
only checks compilation/linking and OTA-slot size.

The opt-in P4 diagnostic image is built without device access with
`tools/build-c6-time-probe.sh`. It uses saved Wi-Fi settings by default; a
private configuration may instead be supplied using `NIHOS_C6_WIFI_CONFIG`.
It accepts only an observed C6 2.13.1 peer before issuing Wi-Fi setup and
never sends OTA commands. The fixture requests snapshots at one-second intervals
after C6 DHCP/DNS until it observes a synchronization or its overall deadline
expires. It is diagnostic code, not the normal NIHOS clock or a production
reconnect loop. The build script and image audit do not qualify a device run.

The address snapshot module and its tests were copied from the existing nihos
experimental custom-C6 work at commit `0b066228`; that code and this integration
remain experimental; one 2.13.1 happy path has been tested on hardware. A
2.13.1 -> 1.4.1 OTA has not been exercised, and an independent unbricking path
is not qualified.

The diagnostic fixture may print a raw DHCP/DNS status on error, including
local IP addresses and DNS server addresses; handle its serial logs as private.

A pinned source overlay, exact sdkconfig and reconstruction notes are in
`ports/esp-hosted-c6-time/reproduction/`.
