# ADR 0045: Integrate factory Hosted networking into normal boot incrementally

- Status: initial opt-in implementation; bounded session, not permanent netd
- Date: 2026-10-27

## Decision

Keep the factory C6 ESP-Hosted firmware for this integration step. CPU0 owns
SDMMC exclusively; builds combining networking and the microSD probe are
rejected. The main loop polls one receive chunk and at most one transmission
per pass, alongside normal UI service. No packet parser runs in an ISR or on
CPU1. The existing independent UI clock measures networking without resetting
or borrowing either scheduler timer.

C6 reset settling is split across main-loop passes. Initial enumeration remains
synchronous with bounded controller waits. Network errors retire the transport
and addresses while the UI and schedulers continue. This is not an IRQ-driven
network service or a hard real-time latency guarantee.

## Memory and cache ownership

DMA data/descriptors remain aligned in internal SRAM. Hosted protocol state and
receive assembly are CPU-only PSRAM objects in the unused end of the existing
private display lease, after the renderer and text grid. A compile-time bound
rejects overlap or overflow. This is the tail's sole additional claimant;
it is outside both task-owned heaps and is not a display DMA source. The
existing external heap whitelist and 48 KiB internal heap floor remain intact.

The combined root and networking modules use size optimization to fit the
resident budget. The default non-network root retains its existing optimization
mode. Shared ROM cache commands mask/restore local interrupts around private
512/64-byte DMA cache operations, avoiding interruption by the display ISR's
cache commands. SDIO command/data waits run with the caller's interrupts enabled.

## Lifetime and retained behavior

The standalone probe still stops at acquisition. The integrated Hosted owner
opts into continued IPv6 NS/Echo processing after acquisition. Transport
backpressure retains a complete response until it is sent. Disconnects clear
both protocol clients. The first integration retires after 120 seconds and
also stops before a short DHCP lease or learned IPv6 preferred/valid lifetime
expires. It does not renew leases or reconnect.

IPv4 DHCP and link-local IPv6 are useful integration gates. Physical SLAAC
requires an advertising AP and is independent of UI coexistence. No normal
application sockets, TCP/IP/BLE host offload, microSD arbitration, long-running
address lifecycle, or cold power-cycle qualification follows from this step.

## Build and evidence

Use `NIHOS_NATIVE_NETWORK=1` with the normal live console/display profile and a
private `NIHOS_C6_WIFI_CONFIG` JSON. Images and generated configuration stay in
private ignored `build/native-device-network/`. Build receipts retain source
and artifact hashes while withholding the credential configuration. See the
[integration measurement](../measurements/2026-10-27-normal-boot-network.md).
