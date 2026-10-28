# ADR 0053: Public SNTP to UTC RTC synchronization

- Date: 2026-10-28
- Status: implemented; public NTP response, RTC write/readback and warm retention physically observed
- Extends: [ADR 0047](0047-default-connectivity-and-board-devices.md) and
  [ADR 0052](0052-default-on-demand-device-drivers.md)

## Behavior

A normal connected native build obtains wall time from `ntp.nict.jp`, then
writes the RX8130CE calendar through CPU0's existing board-I2C owner. RTC stores
**UTC**; JST is a display conversion, not an offset written into the chip.
Scheduler deadlines, timeouts and sleep remain on the monotonic timer.

The C6 must first obtain a valid IPv4 DHCP lease. The DHCP client retains the
first resolver from option 6, including renewal preservation. The bounded time
client resolves the NICT hostname, routes via the lease subnet/gateway, resolves
the next-hop MAC with ARP, and sends one SNTP request over UDP/123. This is a
small purpose-specific client, not a general socket/DNS interface. It accepts
bounded A-record answers for the exact query. DNS TCP, truncated responses,
CNAME chasing, IPv4 options/fragments and IPv6-only NTP are not implemented.

Missing Wi-Fi configuration keeps the existing unconfigured behavior. Missing
AP, address or resolver cannot trigger a clock write. DNS/NTP failure does not
reset C6 or revoke a valid lease. Outstanding replies and cached neighbor state
are revoked on reconnect/address change, while NTP rate limits survive C6
reconnect. No SSID/password or generated credential module is committed.

## Time checks and scheduling

The client checks Ethernet/IP/UDP endpoints, packet bounds, checksums, version,
server mode, synchronized leap state, stratum, root dispersion, nonzero server
timestamps and the echoed request timestamp. It bounds server processing and
round-trip delay to two seconds, estimates receipt time using the server's
receive/transmit timestamps and measured elapsed time, and supports the NTP
2036 era rollover within the RTC's 2000–2099 range. A sample is single-use and
expires after five seconds; the board owner advances it to application time.

Successful polling repeats after six hours. Communication failure uses at
least 64 seconds and exponential backoff; the maximum is 131072 seconds.
RATE replies increase the interval, and other Kiss-o'-Death responses disable
further requests for this boot. Transport backpressure retains the same packet
and correlation token until complete acceptance. This is unauthenticated SNTP
wall time, not a trusted time source for security decisions or a subsecond
accuracy guarantee.

Calendar conversion is tested across all 36525 days of the RTC century. Setting
validates STOP before changing calendar fields, restarts and reads back the
actual calendar, and accepts only the intended UTC second or its immediate
successor with a matching weekday. Failed writes/readback attempt to leave STOP
verified asserted. Alarm, timer and battery policy are preserved; VLF still
returns `NeedsInitialization`. Automatically clearing VLF without the separate
board-selected full register/power initialization is not added here.

## Resources and execution boundary

The new client lives in CPU0's existing private PSRAM service reservation; its
bounded Ethernet staging array is not a DMA source. All board-I2C operations
remain on CPU0 outside interrupts. A separately allowlisted `.flash.time`
extent holds foreground network polling and the network/calendar routines in
the already mapped first 64 KiB page. It never disables that mapping/cache.
Kernel/IRQ/cache-off startup paths and mutable state remain in SRAM.

The image auditor checks RX permissions, exact function names, complete extent
coverage, profile/linker markers, ordering after boot/device code, payload bytes
and the stock two-mapped-segment loader contract. The existing SRAM and stack
regions and minimum 49152-byte heap are unchanged. The credentialed qualified
candidate has 63424 static primary heap bytes, compared with 50432 before this
change: moving the foreground network code offsets the time-client code cost.
These are link-layout figures; existing first-use audio storage remains separate.

## Evidence and limits

The [physical checkpoint](../measurements/2026-10-28-network-rtc-sync.md) compares
the **same credentialed image** before and after the AP became available. Before,
it sent no NTP request and did not write RTC. After, DHCP/DNS/public NTP succeeded,
RTC changed from an invalid calendar to valid advancing UTC, and the original
Flash was verified restored. A separate previously qualified image with no NTP
code then read the retained RTC across a warm reset. Its Flash was also restored.

NTP and RTC application have separate `NIHOS_NATIVE_NTP` and
`NIHOS_NATIVE_RTC_SYNC` reports. `rtc_valid` continues to mean a coherent valid
calendar; it is not an authentication claim. `tools/check-native-time.py` checks
successful sync, unavailable-AP controls and no-NTP retention, with exact
image/ELF/options/log identity and verified restoration.

A [connected device follow-up](../measurements/2026-10-28-connected-devices.md)
observed one failed NTP request and a successful delayed retry while Wi-Fi stayed
acquired and microphone/audio/internal UART operations completed. Its explicit
`recovered-sync` verifier retains the failed attempt; normal `sync` remains
strict about clean first-attempt evidence. The native runtime was unchanged.

Six-hour natural resynchronization, long-duration drift, cold battery/power
retention, VLF recovery and authenticated network time remain separate gates.

## References

- [NICT public NTP service](https://www.nict.go.jp/sts/ntp.html)
- [RFC 4330, SNTP](https://www.rfc-editor.org/rfc/rfc4330.html)
- [RFC 5905, NTPv4 and Kiss-o'-Death](https://www.rfc-editor.org/rfc/rfc5905.html)
- [RFC 1035, DNS](https://www.rfc-editor.org/rfc/rfc1035.html)
- [Epson RX8130CE application manual ETM50E-10](https://download.epsondevice.com/td/pdf/app/RX8130CE_en.pdf)
