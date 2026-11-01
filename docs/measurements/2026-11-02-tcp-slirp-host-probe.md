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

Run the SSH variant with `SLIRP_PREFIX=/path/to/libslirp NIHOS_SSH_SLIRP=1
ZIG=/path/to/zig python3 tools/ssh_openssh_probe.py`.

Run with `SLIRP_PREFIX=/path/to/libslirp ZIG=/path/to/zig sh
tools/run-tcp-slirp-probe.sh`. The dependency is external and is not vendored.
The test creates a temporary build directory, a local listener, and a child echo
process, all removed or reaped on normal completion.
