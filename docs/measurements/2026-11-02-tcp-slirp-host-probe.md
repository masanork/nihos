# Experimental TCP against libslirp and host echo

`tools/run-tcp-slirp-probe.sh` exercises the Zig IPv4/TCP active open and
stream against an independent libslirp TCP peer. The peer proxies to an
ephemeral loopback echo server. The fixture drops the first SYN-ACK and the
first response data segment, verifies retransmission and echo bytes, and
waits for both FINs and acknowledgements. The fixture also responds to ARP;
it is not the nihos network service.

On 2026-11-02, macOS arm64, libslirp 4.9.7 and Zig 0.17.0: passed. The
observed response retransmission occurred after about 12 seconds; the complete
test took about 18 seconds. This is one host interoperability case, not proof
of general TCP conformance, physical Wi-Fi/SDIO, an integrated socket service,
SSH over this TCP path, or Tab5 behavior.

Run with `SLIRP_PREFIX=/path/to/libslirp ZIG=/path/to/zig sh
tools/run-tcp-slirp-probe.sh`. The dependency is external and is not vendored.
The test creates a temporary build directory, a local listener, and a child echo
process, all removed or reaped on normal completion.
