# Hosted long send: link-only fixture

Run `sh tools/build-hosted-long-link.sh` from the repository root to link and
audit the experimental sender/controller/DMA/cache path for RV32. The script
also checks that corrupt ROM symbols and DMA layout are rejected.

**Never flash or boot this ELF.** Its register and credit providers are stubs;
it has no startup, stacks or boot descriptor. The 128-KiB SRAM window is for
standalone placement checks, not the normal firmware's memory budget.

Source: `tools/probes/hosted-long-send.zig`. Results and remaining physical gates:
[`factory-c6-udp-boundary`](../../docs/measurements/2026-11-01-factory-c6-long-udp.md).

## Separate boot diagnostic

`NIHOS_C6_PROTOCOL=hosted NIHOS_C6_LONG_DMA=1 sh tools/build-c6-sdio-probe.sh`
builds a separate P4 boot diagnostic in `build/c6-hosted-long-probe`. It uses
`boot-bus.zig` with the existing power/reset/Hosted/STA sequence. CPU1 remains
parked and has no private stack reservation in this profile. Normal profiles
retain the original layout and provider.

To enable 64-byte and 1200-byte UDP payloads after DHCP, also specify
`NIHOS_C6_UDP_PEER_IP`, `NIHOS_C6_UDP_PEER_MAC`, and optionally
`NIHOS_C6_UDP_PEER_PORT` (default 44444). The peer must be in the acquired local
subnet; its MAC is explicit because this probe does not resolve ARP or gateways.
Without a peer, the boot diagnostic performs no long-packet send.

Run `python3 tools/hosted-udp-peer.py --port 44444 --timeout 30 --expect both` on the peer to
record full payload equality and SHA-256. Device send completion and peer
receipt are separate evidence. Build success does not qualify boot, DMA
completion, UDP, or interoperability.

For a bounded sequence measurement, also set `NIHOS_C6_UDP_BURST=1` and run
the peer with `--expect burst --echo`. The device sends 16 numbered 1200-byte
payloads at a nominal 250 ms interval after the short control. Each peer echo
and device receipt is attributed to an attempt; the device waits two seconds
after its final send. Use `tools/analyze-hosted-udp-burst.py` on the paired logs.
This is a small diagnostic sample, not a transport reliability guarantee.
For a separate longer observation window, `NIHOS_C6_UDP_SETTLE_MS=8000`
keeps receiving for at least eight seconds after the final completed write.
