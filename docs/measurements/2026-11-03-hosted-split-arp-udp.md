# Hosted Network Split ARP and UDP on Tab5

On 2026-11-03 JST, one Tab5 resolved a same-subnet Mac through the new
lease-bound ARP route and then completed a 16-packet generic UDP burst. The
clean diagnostic source was commit
[`62d58f8904113cb47d3227d938aebe847782c51b`](https://github.com/masanork/nihos/commit/62d58f8904113cb47d3227d938aebe847782c51b),
preserved on `codex/hosted-udp-arp-physical`. It combines this route change
with the generic UDP diagnostic from PR #141 and adds a temporary physical
fixture. The P4 app SHA-256 was
`fa12167cc62f42bd7f7d435f9c50b13db5493805c33667734f5782df105cb9d6`.
The SRAM audit reported 19,136 bytes of unused primary heap.

The C6 reported chip 13 and ESP-Hosted 3.0.10. After the C6-owned address
was acquired, the P4 sent a Hosted station ARP request, accepted a matching
reply under its current address generation, and compared the resulting MAC
with the independently configured Mac peer. The diagnostic's `wifi_step=10`
was reached only after that comparison. It then used the resolved MAC to send
16 distinct 1,200-byte UDP payloads. The Mac independently validated and
echoed all 16; P4 matched all 16 echoes, mask `0xffff`, and waited 8,000 ms
after the final send. The paired capture analyzer passed.

The device capture SHA-256 was
`faf8494ba581f66bd03d29e018de92b5b66c0cbe634d9ea509368e4161d777a1`;
the raw peer JSON SHA-256 was
`090ff3cf591d92c1542ff9405d1daf2dc7a97c96d1d64de033a1e6d919c93d28`.
The raw captures remain private under
`/private/tmp/nihos-hosted-arp-physical-results-20261103/`.

The shared writer lock and exclusive serial lease were held. P4 identity,
security flags, flash size and partition geometry were checked; the complete
16 MiB flash was backed up and verified before installation. The original
contents were restored and all 16 MiB verified against backup SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.
Periodic native firmware output was observed after reset. C6 firmware was not
rewritten. The Mac connection identity was privately checked immediately
before installation; the C6 SSID and BSSID were not captured.

This establishes one local next-hop resolution and bounded burst for the
listed candidate. Gateway resolution remains host-tested only; an OS socket,
general peer discovery, long-duration reliability, TLS/QUIC, iroh and madowi
interoperability are not established by this experiment. The temporary
fixture aborts on a zero or partial ARP write and requires an independently
configured expected MAC; it is not a general runtime ARP service.
