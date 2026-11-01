# Factory C6: long UDP diagnostic

Tab5's factory ESP-Hosted 1.4.1 firmware remains unchanged. This is an opt-in,
CPU0-only P4 diagnostic with a single SDIO owner and CPU1 parked. It does not
connect long DMA to normal networking or provide a UDP socket, QUIC, TLS, or
iroh. The peer is an explicitly configured same-subnet IPv4/MAC endpoint.
The 1200-byte UDP payload produces a 1254-byte Hosted frame and uses one
1536-byte padded, three-block SDIO write. Frame completion is not peer receipt.

## Prior physical observations

The following evidence was recorded on the isolated experimental branch, with
its own candidate/source hashes; it does not qualify a later rebased image.
Each test backed up and verified P4 flash, verified the candidate, restored
loader/application, and verified the full 16 MiB flash. The restored firmware's
boot log was not captured. C6 firmware and partition table were not changed.

- [Bounded burst](evidence/2026-11-01-hosted-udp-burst-physical.json): one
  16/16 send-and-echo run; a separate attempt stopped at PowerEnable before UDP.
- [Reverse identifiers](evidence/2026-11-01-hosted-udp-reverse-physical.json):
  16/16, 15/16, 15/16. Missing identifier 1 was last in send order in both
  partial runs; identifier 16 arrived first.
- [Two-second pause](evidence/2026-11-01-hosted-udp-pause17-physical.json):
  one 16th echo preceded the 17th write; in two runs the 17th arrived but the
  16th was never observed.
- [Short tail](evidence/2026-11-01-hosted-udp-short-tail-physical.json): the
  short marker arrived in all three runs; one run missed the preceding long
  packet. A later short transmission did not guarantee long-packet delivery.
- [500 ms interval](evidence/2026-11-01-hosted-udp-interval500-physical.json):
  16/16, 14/16, 15/16; missing packets were at the tail. Device-measured
  adjacent completion intervals were 500–510 ms.
- [CPU staging audit](evidence/2026-11-01-hosted-udp-staging-audit-physical.json):
  15/16 in three runs; the CPU-visible staging frame and padding matched the
  intended bytes on all 48 writes. This does not observe SDIO wire data or the
  C6 receive buffer.

The samples do not establish a general loss rate or locate the loss. The peer
was independently scheduled; macOS UDP statistics were system-wide, and BPF
capture was unavailable without administrator privileges. A returned credit is
not Wi-Fi transmission or application delivery. Factory firmware equivalence
to any published source build is unverified.

## Integration boundaries

The long-DMA buffer is explicit diagnostic state. The normal runtime retains
its existing short path and shared SDMMC owner. Before enabling generic UDP in
normal operation, establish bounded ownership, memory and backpressure, safe
reset/reconnect, real packet delivery under representative load, and coexistence
with Wi-Fi/BLE, input and storage. QUIC/TLS and madowi identity/authentication
need independent implementation and end-to-end qualification.
