# Experimental TCP against libslirp and host echo

`tools/run-tcp-slirp-probe.sh` exercises the Zig IPv4/TCP active open and
stream against an independent libslirp TCP peer. The peer proxies to an
ephemeral loopback echo server. The fixture drops the first SYN-ACK and the
first response data segment, verifies retransmission and echo bytes, and
waits for both FINs and acknowledgements. The fixture also responds to ARP;
it is not the nihos network service.

On 2026-11-02, macOS arm64, libslirp 4.9.7 and Zig 0.17.0: passed. The
observed response retransmission occurred after about 12 seconds; the complete
test took about 18 seconds. The echo case alone does not prove general TCP
conformance, physical Wi-Fi/SDIO, an integrated socket service, SSH, or Tab5
behavior.

The follow-up `NIHOS_SSH_SLIRP=1` mode of `tools/ssh_openssh_probe.py`
connects the same experimental TCP implementation through libslirp to a
temporary OpenSSH server. It passed host-key pin rejection, key exchange,
Ed25519 public-key login, interactive PTY input/output, SSH channel closure,
and TCP FIN exchange on 2026-11-02. The C/Python bridge drives polling, ARP,
entropy and credentials and uses a fixed test-only initial sequence number.
The probe starts TIME_WAIT but does not wait its full duration. It does not
demonstrate native network integration, device entropy, secure key storage,
Wi-Fi/SDIO or Tab5 behavior.

A later run resolves the next-hop MAC via the Zig ARP resolver before opening
TCP instead of using a fixed destination MAC. The host fixture still provides
the test lease and responds to ARP requests from libslirp; this is not native
lease ownership, reconnect handling, or physical Ethernet/SDIO qualification.

The current SSH probe uses `tcp_link.zig` to own the outgoing Ethernet frame,
resolve ARP and progress the TCP connection. The fixture continues to provide
frame I/O, DHCP-like lease values and serialization; no normal device service
has adopted this owner.

The subsequent host run also routes frames through `hosted_tcp_service.zig`
and the Hosted encoder/decoder before handing Ethernet to libslirp. Separate
tests cover lease-epoch invalidation, staged TX, backpressure and ambiguous
partial sends. This does not exercise an SDIO transport or live DHCP client.

The next host fixture uses an actual `hosted_station.Client` in a **synthetic
bound state** and calls the station lease/scheduling adapter before TCP sends.
OpenSSH PTY/FIN passes through this path. Host tests also cover renewal,
expiry, disconnect, reset and station/TCP priority. DHCP packet acquisition,
normal native owner scheduling and device SDIO remain
unverified by this fixture.

The latest host probe also routes received frames through a four-frame
`hosted_tcp_rx.zig` queue. Targeted tests cover deferral during staged TX,
station ARP processing, overflow isolation and connection-generation changes.
The host probe does not establish physical SDIO buffering or concurrency safety.

The Hosted TCP service now limits each write to 446 bytes and rejects frames
over 512 bytes, matching the normal C6 short-send size bound. A host test
checks that a maximum-sized data frame is 512 bytes; it does not execute a
physical SDIO transaction.

An RV32 code-generation probe imports the same Hosted station module used by
the native service and instantiates TCP open, RX, TX completion and reset.
This checks module compatibility and a 24 KiB owner size ceiling, not a linked
image, PSRAM placement, or execution on a device.

The native network service has an opt-in `experimental_tcp` option that
reserves a separate aligned tail for the TCP owner, retires it on network
stop/retry, and delivers station-processed RX to it. TCP RX failures are kept
separate from station failures. The architecture probe compiles both settings.
The experimental owner also schedules TCP TX through the existing short SDIO
sender after station, time and BLE work, retaining any staged TCP frame across
backpressure. An experimental CPU0-only interface offers open, readiness,
partial I/O, half-close and a borrowed SSH adapter with lease/epoch validation.
Native adapter construction is RV32-codegen tested; the OpenSSH fixture uses
the same adapter with a synthetic station. Callers must supply
secure connection randomness before production use. Production configuration
does not enable the option, and xy does not call it.

A local `NIHOS_NATIVE_EXPERIMENTAL_TCP=1` connected device image linked and
passed the image audit: the primary SRAM heap was 50,240 bytes against the
49,152-byte floor. The network state occupied 21,120 bytes of an explicitly
bounded 40,960-byte interval at `0x48206000` within the boot-owned sqld
reservation, disjoint from the copied client buffers and store. The TCP and
network foreground code was audited in the mapped xy Flash range. This is a
build/image result; it does not prove startup, SDIO, Wi-Fi, PSRAM behavior, or
SSH on Tab5. No experimental image was written to a device.

The SSH/libslirp bridge also uses `ssh_hosted_tcp_io.zig` for TCP stream
reads and writes. Its station lease remains synthetic; this is not a live
native network-service or device test.

With `NIHOS_SSH_LIFECYCLE=1`, the same fixture exercises the xy lifecycle
controller from an established TCP stream through caller-supplied key material,
SSH authentication, terminal input and output, SSH close, TCP FIN and owner
retirement. The native workspace adapter and its reserved storage bounds are
also checked by freestanding RV32 code generation. The fixture supplies the
network and credentials; no native application starts this controller yet.
The terminal bridge derives distinct per-operation padding from each fresh
caller-supplied random seed; this does not provide a device entropy source.
The volatile profile parser accepts a numeric IPv4 endpoint, OpenSSH SHA256
host-key fingerprint and raw Ed25519 seed, and supports explicit erasure. It
is exercised through the same profile lifecycle entry points used by the
native workspace adapter against the local OpenSSH server, with xy terminal
input/output and TCP FIN; a wrong fingerprint is rejected and both success and
failure paths clear the fixture's profile. It does not provide a provisioning
UI or protected storage. The fixture fills a bounded transient form before
starting the profile; its display accessor never returns seed bytes, and its
submission and cancellation erasure are unit tested. This form is not wired
to a native application. A portrait/landscape setup renderer receives only
public field text or the seed length, never the seed bytes; its masked view
and soft-keyboard layout were checked in host render tests. The host fixture feeds it through
the xy model's private serial input port, verifies successful authentication,
checks cancel-and-erase and rejection of a wrong host fingerprint. The model rejects private
input while the VM or deferred queues are active and wipes deferred buffers
after replay or overflow. The session owner erases its signing seed when
authentication completes and its profile on close or failure; the OpenSSH
fixture checks both. This host test does not qualify physical keyboards,
serial transports, display masking or device memory custody. ESP32-P4 RNG output
must not be treated as cryptographic entropy without meeting the documented
[entropy-source conditions](https://docs.espressif.com/projects/esp-idf/en/v5.5/esp32p4/api-reference/system/random.html);
the existing SQL random callback does not establish those conditions for SSH.

The foreground app driver refuses setup if its injected entropy provider is not
available. It requests fresh bytes for the TCP port and initial sequence, the
SSH exchange secret and cookie, and each packet-producing tick; failure cancels
the session and clears its profile. The host fixture supplies `os.urandom` and
exercises this same driver through OpenSSH. The RV32 probe uses deliberately
fixed test bytes for code generation only. No qualified native entropy provider
or device application enables this driver yet. The experimental native loop
has a foreground binding, but its unavailable entropy provider gates the
binding at compile time: no SSH session or credential input runs on device.
Enabling that gate also requires independently qualifying the entropy source,
moving SSH cryptographic code out of the constrained SRAM foreground safely,
and validating the resulting image. The host fixture drives the common
foreground owner from the xy home screen and exercises navigation cleanup.
The TCP service permits at most
32 sequential attempts per lease generation, each with a distinct local port;
it retains used ports until the lease changes. The driver does not reset the
station or claim automatic reconnect support.

The separate `tools/tcp_reconnect_probe.py` fixture keeps one synthetic station
lease and libslirp instance while opening two TCP sessions. It exchanges data
and completes FIN for both, rejects the first local port on reuse, and accepts
a different local port. This is a host TCP test, not an SSH reconnect or a
device result.

An optional `NIHOS_SSH_AUTOIDENT=1 NIHOS_SSH_AUTOKEX=1` host run exchanges
identification with `ssh_identification.zig` and advances first key exchange
using `ssh_kex_driver.zig`; the fixture supplies fresh random bytes. An
additional host-socket control uses an incorrect pin and expects rejection.

Run the SSH variant with `SLIRP_PREFIX=/path/to/libslirp NIHOS_SSH_SLIRP=1
ZIG=/path/to/zig python3 tools/ssh_openssh_probe.py`.

Run with `SLIRP_PREFIX=/path/to/libslirp ZIG=/path/to/zig sh
tools/run-tcp-slirp-probe.sh`. The dependency is external and is not vendored.
The test creates a temporary build directory, a local listener, and a child echo
process, all removed or reaped on normal completion.
