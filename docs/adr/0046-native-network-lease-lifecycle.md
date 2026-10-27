# ADR 0046: Maintain leases and recover the native network owner

- Status: implemented and host-tested; physical early renewal ACK and controlled C6-reset recovery passed; natural timing and long-duration gates remain
- Date: 2026-10-27
- Extends: [ADR 0045](0045-normal-boot-network-integration.md)

## Decision

Remove the fixed 120-second session limit from the opt-in normal-boot network
owner. Keep exclusive CPU0 ownership of SDMMC and the existing SRAM/DMA and
PSRAM-tail boundaries. Initialization is still opt-in and credentials remain
in private generated configuration. This is not a general sockets service.

DHCP maintains T1, T2 and expiration from the first accepted REQUEST send time
of a transaction. A matching ACK restarts those deadlines; a delayed ACK does
not move the start to its reception time. Server options 58/59 are accepted
only with `0 < T1 < T2 < lease`; absent timers use one-half and seven-eighths
of the duration. Renewal uses a fresh transaction ID, ciaddr/source IPv4 and
unicast to the selected server, omitting options 50/54. Rebinding broadcasts
and can accept another server. Retransmissions use half the remaining stage
time with a 60-second minimum, while T2/expiration still take precedence.

The initial ACK supplies the bounded next-hop Ethernet address for renewal.
A minimal leased-IP ARP responder allows unicast server replies. It is not a
general ARP cache or IPv4 ICMP stack. The next hop can become stale; T2
broadcast is the recovery path. Malformed packets, mismatched transactions,
wrong renewal servers and invalid timers do not extend a lease. A NAK or
expiration clears both protocol clients and any serialized outgoing packet.
A pending T1 unicast is replaced when T2 is reached even under backpressure.

The native owner resets C6/SDMMC after a failed attempt, discards receive and
protocol state, and retries with delays 1/2/4/8/16/32/60 seconds, capped at 60.
A stable ready interval resets the delay progression. Scheduler timers and
normal UI service continue. A broken time source stops retries. Acquisition
has a 100-second owner deadline; no fixed session deadline applies after
acquisition. Expired learned IPv6 preferred/valid lifetimes conservatively
restart the connection; full SLAAC lifetime refresh remains out of scope.

## Diagnostic boundary

`NIHOS_NATIVE_NETWORK_TEST=1` requires `NIHOS_NATIVE_NETWORK=1`. It requests
one early renewal ten seconds after initial acquisition completes, without
altering the server's lease duration or expiry. Forty seconds after readiness
it resets C6 once to exercise recovery. The triggers wait for successful
readiness; absent APs do not consume the test. Normal builds have both
injections compiled out. Diagnostics are not physical qualification until
the corresponding ACK and re-acquisition are observed.

References: [RFC 2131, section 4.4.5](https://www.rfc-editor.org/rfc/rfc2131.html#section-4.4.5),
[RFC 2132, sections 9.11–9.12](https://www.rfc-editor.org/rfc/rfc2132.html#section-9.11).
See [measurements and remaining gates](../measurements/2026-10-27-network-lease-lifecycle.md).
The subsequent [positive device result](../measurements/2026-10-27-network-lease-device.md)
records the real renewal ACK and recovery after the AP became available.
