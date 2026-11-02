# Hosted 3 split UDP burst: first preflight

On 2026-11-02 JST, the first 16-packet candidate from clean source commit
`aeaf90b801a7f8fbd9d2ac3e3f06c22316b1e78e`, P4 app SHA-256
`b472a4f81f91afeef8e81c9abf254bb9f64d512598c66a4b108f1f86003359d9`,
stopped in C6 connection preparation (stage 5, error code 23). The P4
reported chip 13 / Hosted 3.0.10 and zero sends; the independently bound Mac
peer recorded zero datagrams. The error code was not independently decoded,
and this run does not establish burst delivery or loss.

The full 16 MiB P4 flash was backed up, verified, restored and verified
against SHA-256 `06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.
The C6 firmware was not rewritten. The raw P4 capture SHA-256 was
`c56a1ef4442ee99021acb6ca1582e780f0650cbcfacebf806e0f6ac97e505076`;
private artifacts are under
`/private/tmp/nihos-hosted3-split-udp-burst-physical-20261102/`.
The restored P4 application's boot was not captured.

Review after this failure found a separate acquisition edge case: if the
address exchange became ready while a Hosted control frame was only partly
received, the fixture could call the exchange's `tx()` and inadvertently
start its time request. The subsequent change drains such a frame before
handoff and rejects unexpected time-request states. This is a plausible
failure mechanism, not a confirmed decoding of error 23.

A subsequent corrected candidate from clean commit
`56f8e0a1c1213ec286a19751f00a7b62a564d383`, P4 app SHA-256
`4b8a61963dbdd129a1736de157b08f9283aaa5e5d29b8097f20d4fb20512a504`,
was built and audited with 26,880 bytes of unused primary SRAM. Before the
candidate was installed, the user reported that the Mac had joined a different
network. The independent peer-identity gate was deliberately failed. No P4
candidate was written and no UDP packet was sent. The 16 MiB P4 backup had
already been read and digest-verified against
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`;
the existing P4 firmware was reset, but its subsequent boot was not captured.
The exclusive serial and writer leases were released. Private artifacts are
under `/private/tmp/nihos-hosted3-split-udp-burst-physical-20261102-v2/`.

The later [2026-11-03 burst](2026-11-03-hosted3-split-udp-burst.md) completed
16 paired round trips and verified restoration. It does not independently
decode error 23 or prove the cause of this first preflight failure.
