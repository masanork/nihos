# Hosted 3 Network Split: 16-packet UDP burst

On 2026-11-03 JST, one Tab5 and a Mac completed one bounded burst using the
opt-in Hosted 3 Network Split diagnostic. The clean P4 fixture source was
`7801d31ca8b4f45640e0d745beb4194fb28d678c`; the app SHA-256 was
`d7fc1a130ab51cc24e5183d0d3085650eb736da320be3a2830c1499f93643c4b`.
The image audit reported 26,688 bytes of unused primary heap. The C6 reported
chip 13 and Hosted 3.0.10. Its flash was neither read back nor rewritten.

The C6-owned address snapshot was used with P4 UDP source port 49152. The P4
reported 16 complete sends of distinct 1,200-byte payloads. The independently
bound Mac peer received and validated all 16, and reported echoing each. The
P4 observed 16 matching echoes, with mask `0xffff`; its final wait was 8,000
ms. The [redacted evidence](evidence/2026-11-03-hosted3-split-udp-burst.json)
records counts, exact fixture identity, capture hashes and restoration status.

The Mac Wi-Fi interface was active, and its address, MAC, SSID and BSSID
identities were checked privately before installation and again after the run.
The 16 paired round trips establish local connectivity for this run. The C6's
SSID and BSSID were not captured, so the observations do not establish that
both devices used the identical physical AP. This sample does not establish a
general loss rate, long-duration reliability, normal-service socket operation,
QUIC/TLS, iroh or madowi interoperability.

The common writer lock and kernel-enforced exclusive serial lease were held.
The P4 identity, security flags, detected 16 MiB flash and partition geometry
were checked. The complete flash was backed up and verified before the
temporary fixture was installed, then the original contents were restored and
all 16 MiB verified against SHA-256
`06140086d05c94f5e8586c89f516d56d31b6340429526796448582a2e1bec435`.
After reset, the restored native firmware's periodic touch/device logs were
observed without another reset. Raw captures and backup remain private under
`/private/tmp/nihos-hosted3-burst-physical-20261103/`.

This run follows the earlier [burst preflight](2026-11-02-hosted3-split-udp-burst-preflight.md)
that stopped before sending with error code 23. The new result does not prove
the cause of that earlier failure or establish which change resolved it.
