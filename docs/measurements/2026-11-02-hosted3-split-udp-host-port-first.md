# Hosted 3 Network Split host-port diagnostic: power-enable failure

On 2026-11-02, a bounded physical attempt used the P4 diagnostic from clean
commit `d8d758734f1d33a3e6d8a28181d96ac20de8334d`, application SHA-256
`32206f5cd0d8b68d03b6825ff361c6dc76ba6964577ea78a0c60cf0275826cc4`,
with its UDP source port changed to the P4-owned range. It stopped at stage 1
with error code 3 during the C6 power-enable stage, before a Hosted handshake
or UDP send. The separately bound Mac peer recorded no datagrams. No conclusion
about the corrected UDP port or round-trip behavior can be drawn from this run.

The writer lock and exclusive serial lease were held. The entire 16 MiB P4
flash was backed up, verified, restored and verified against SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.
The C6 firmware was not rewritten. Capture SHA-256:
`d5da6315de014cef58cf81e13e0fa36a886732806280137fdceb22475f869ad5`.
Raw private evidence is under
`/private/tmp/nihos-hosted3-split-udp-physical-20261102-v3/`.
