# Hosted 3 generic UDP diagnostic on Tab5

On 2026-11-03 JST, a Tab5 and Mac completed one bounded 16-packet
Network Split burst. The P4 fixture was built from clean commit
`2987b1829f1e74e5b860fe745af250ef829bf7ca`; its app SHA-256 was
`00b151b8ecfe139cf0dda6b11225826742f54f5640ae11cbbd5c07f830abe810`.
The SRAM image audit reported 23,680 bytes of unused primary heap. The C6
reported chip 13 and ESP-Hosted 3.0.10; its flash was not rewritten.

The diagnostic owner acquired the C6-owned address and used the generic
`hosted_udp_sender.Sender` to encode and submit each 1,200-byte payload. Its
existing exclusive owner drained Hosted frames and invoked `Sender.poll`;
it did not exercise `Sender.step`. On receive, `hosted_udp_lease.Lease`
decoded and checked the local destination before the fixture also matched
the configured peer and diagnostic payload. The Mac independently validated
and echoed all 16 distinct payloads; the P4 matched all 16 responses. Both
received masks were `0xffff`, and the final observation wait was 8,000 ms.
The paired capture analyzer passed. The device capture SHA-256 was
`a3182923812026c8ad5202f4f72dfd9dc8338fc73887fcdf94ac6dc56931822a`;
the raw peer JSON SHA-256 was
`a5ce8ee74c1c6e7850e7346d506fab50ed4f81ca554bae4b38b30d98c4779892`.
Raw captures remain private under
`/private/tmp/nihos-hosted3-generic-physical-20261103/`.

The Mac connection identity was checked privately against the prior run
immediately before installation. The C6 SSID and BSSID were not captured.
This is one short same-subnet diagnostic with an explicit peer MAC, not a
generic OS socket, ARP, routing, long-duration reliability, TLS/QUIC, iroh,
or madowi interoperability qualification.

With the shared writer lock and an exclusive serial lease held, P4 identity,
security flags, flash size, and partition geometry were checked. The entire
16 MiB flash was backed up and verified before installation. After the test,
the original contents were restored and all 16 MiB verified against backup
SHA-256 `06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.
After reset, periodic native firmware output was observed via passive serial.
