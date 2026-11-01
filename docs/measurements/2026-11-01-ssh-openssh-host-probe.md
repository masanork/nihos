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
interactive PTY on the host. Python still drives transport and session
ordering; it is not a complete nihos SSH client, network service, xy terminal,
Tailscale, or Tab5 device validation.
