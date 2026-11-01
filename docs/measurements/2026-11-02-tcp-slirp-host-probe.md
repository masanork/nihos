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

Run the SSH variant with `SLIRP_PREFIX=/path/to/libslirp NIHOS_SSH_SLIRP=1
ZIG=/path/to/zig python3 tools/ssh_openssh_probe.py`.

Run with `SLIRP_PREFIX=/path/to/libslirp ZIG=/path/to/zig sh
tools/run-tcp-slirp-probe.sh`. The dependency is external and is not vendored.
The test creates a temporary build directory, a local listener, and a child echo
process, all removed or reaped on normal completion.
