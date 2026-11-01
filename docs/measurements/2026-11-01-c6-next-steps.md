# C6 offload: next qualification steps

The normal P4 profile has demonstrated one C6 SNTP snapshot reaching the RTC
on one Tab5; see [the physical record](2026-11-01-c6-time-native-rtc.md). The
SNTP value is unauthenticated and the P4 candidate was restored after the
capture. This is not a CPU-saving or long-duration result.

Priorities before adding more application services to C6:

1. **Update and recovery.** The reproduced 2.13.1 application's sdkconfig
   disables `CONFIG_BOOTLOADER_APP_ROLLBACK_ENABLE`; the device's existing
   bootloader was not read back or replaced by the application OTA, so its
   actual configuration is not established. The reproduced partition table
   has two OTA app slots and otadata. Verify the device's real bootloader and
   partition behavior, and independently demonstrate recovery from a C6 app
   that cannot serve Hosted RPC before depending on repeated OTA deployments.
   An application-only upgrade cannot itself establish bootloader rollback.
2. **Failure isolation and reconnection.** The opt-in native profile now
   retires timed-out time requests without resetting a live station, and ignores
   late acknowledgements/results that cannot match the current request. Host
   tests cover queued and waiting timeouts and stale messages; physical timeout
   injection and BLE/UI continuity are not yet demonstrated. Invalid responses,
   partial transfers, disconnect, DHCP changes, and C6 restart still need
   separate classification and qualification; protocol errors may reset C6.
3. **Measure the existing offload.** Compare factory/P4-SNTP and C6-SNTP under
   the same P4 feature profile, AP and workload. Record P4 busy time, polling,
   SDIO traffic, heap and responsiveness, and C6 free/minimum heap and stack
   headroom. The observed native candidate audit showed 49,664 bytes P4 heap
   against the 49,152-byte floor; it is not evidence of spare capacity under
   the full default UI/storage profile.
4. **Qualify time lifecycle.** Verify time progression and resynchronization
   beyond the six-hour interval, AP loss/recovery and power-cycle RTC behavior.
   Host simulation of the resync interval does not substitute for a device
   soak or cold-retention test.

Once these gates have results, prioritize the next service using a concrete
nihos application workload. C6-owned DNS/TCP and a bounded HTTP(S) client may
be useful for conventional cloud APIs; they require measured headroom,
backpressure, reset invalidation, and certificate/clock policy. Keep a P4 UDP
path for QUIC/iroh evaluation: TCP or HTTPS offload does not itself implement
QUIC. Do not treat the HTTPS experiment under `unused-https/` as an enabled or
qualified service.
