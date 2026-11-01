# Factory Hosted 1.4.1 C6 OTA experiment

This is experimental preparation. No C6 OTA has been performed. The normal
Hosted station does not call this code. The RPC transaction in
`src/net/hosted_ota.zig` is transport-independent: it is not yet connected to
the P4 SDIO owner and cannot by itself update a device.

The public 1.4.1 slave example handles RPC 272/273/274. Begin erases the
inactive OTA partition; Write appends; End validates, selects the new boot
partition and schedules a reboot. A successful End response is not a boot or
network-health confirmation. There is no automatic rollback demonstrated on
the Tab5. M5's distributed full-flash image has two 1536 KiB OTA app slots;
the device's actual layout, security configuration and firmware identity are
not established solely by its 1.4.1 version response.

The isolated client requires an externally reviewed SHA-256, a C6 application
image no larger than the slot, and a continuously immutable image buffer. It
checks the magic, chip ID and application descriptor marker, not the whole image format, signature or boot
compatibility. It emits one frame per request, limits image chunks to 384 bytes,
and permits only one outstanding RPC. A nonzero response fails the transaction.
A timeout, partial or uncertain send, reset or lost exclusive ownership must
call `fail()`; no write may be retried because the C6 write is append-only.
The calling transport must enforce a deadline and process stale traffic without
reusing a UID. Completion means only the End response was accepted.

Existing comparison artifact (build-only, not selected for flashing): Espressif
1.4.1 Hosted example built against IDF f420609c, app 1,078,848 bytes, SHA-256
`8ab3385f382786e157597a326ce709efdc70857f527f4e42bb7abcbe9f004aea`.
It preserves the Hosted architecture and its build partition table matches the
M5 distributed image, but runtime and BLE/Wi-Fi compatibility are unverified.
An earlier C6 netif/UDP size probe fits too, but is explicitly not a runnable
network service: its Hosted/netif RX ownership is unresolved. NTP should follow
an independently validated receive and address ownership design, not be added
to that size-only binary and represented as working.

Before a real OTA test, integrate a dedicated explicit P4 update mode with
exclusive transport ownership, fixed reviewed image and digest, bounded deadline,
correct DMA handling, progress and failure reporting, and post-reboot version,
Wi-Fi/BLE, and repeat-update checks. Validate image format using esptool and
verify security/partition compatibility, exact candidate identity, board write
ownership, and a recoverable path. Existing ROM downloader documentation is a
recovery option but has not been proven for this individual device. Do not
send OTA Begin merely to detect support: it may erase the inactive slot.

## Bounded SDIO pump preparation

`hosted_ota_pump.zig` drives the OTA client over the same `send`/`receive`
contract as `c6_sdio.ProfileStream`. The frame is retained when a zero send
means no credits and no bus write. A partial send, error, clock reversal or
deadline retires the entire transaction; a sent request is never replayed.
Tests cover a complete simulated transaction, zero-credit, partial write and
timeout, and `hosted_ota_rv32_probe.zig` instantiates the path for a
freestanding RV32 compile. This is not yet wired into a real device fixture.

The existing P4 SRAM-only fixture has 128 KiB of SRAM and cannot hold the
1,079,120-byte image. A tested, bounded image source (such as an audited flash
mapping or external streaming protocol) must be implemented before its loop
can drive this pump. C6 ROM recovery has not been verified on this board. No OTA
Begin, C6 Flash write or P4 fixture flash was performed during this stage.
