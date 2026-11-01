# SSH first key exchange: local OpenSSH probe

Run `ZIG=/path/to/zig python3 tools/ssh_openssh_probe.py` on a host with
`/usr/sbin/sshd` and `ssh-keygen`. The probe generates a temporary Ed25519 host
key, starts an isolated loopback server and checks the independently provisioned
SHA-256 pin. It sends NEWKEYS and an encrypted `ssh-userauth` service request,
then verifies the encrypted service acceptance with the Zig packet decoder.
An incorrect pin must be rejected. A temporary Ed25519 client key is then
authorized for the current local user, used to sign a Zig-built authentication
request, and the Zig channel state machine requests a PTY and an interactive
shell, sends a command and observes its output and channel close. The
temporary server, keys, and files are removed on exit.

Observed locally on macOS with OpenSSH 10.5p1: the probe passed. This validates
the tested initial key exchange, signed public-key authentication and an
interactive PTY on the host. Zig now validates the initial key-exchange,
service and authentication ordering, packet framing, sequence numbers and
channel state. A Zig nonblocking socket pump handles partial I/O; the host
probe supplies Python socket callbacks with writes limited to three bytes and
reads limited to 31 bytes. Python still drives connection setup and some
transport-level messages; this is not a complete nihos SSH client, network service, xy terminal,
Tailscale, or Tab5 device validation.
