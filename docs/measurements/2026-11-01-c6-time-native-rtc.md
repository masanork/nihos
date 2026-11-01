# C6 time to native P4 RTC: Tab5 observation

On 2026-11-01, one Tab5 ran the normal native P4 network/device profile with
`NIHOS_C6_TIME_OFFLOAD=1`, `NIHOS_C6_IPV6=0`, and XY workspace, normal
storage, camera ID, and SQLD disabled. The P4 source commit was
`1e74f26d740008aafe38f796f30d80c6067cf042`; the native app SHA-256 was
`81a84ef55460abd86f62820c1c2c365662e2ba63c396170c7516d7649bc3a766`.
The C6 had previously been updated by SDIO OTA and reported version 2.13.1;
see [the OTA evidence](2026-11-01-c6-time-ota-upgrade.md).

The serial capture reported IPv4 network readiness, then six time requests and
one accepted reply. The sample and RTC write both reported Unix time
`1793534816` (2026-11-01 12:06:56 UTC), with one applied RTC update and zero
reported failures. Subsequent RTC reads were valid and advanced through
12:07:04 and 12:07:10 UTC; UI frame and both core tick counters also advanced.
The source is the C6 time service in this build configuration; its SNTP result
is unauthenticated and does not report stratum or RTT.

Before installing the P4 candidate, all 16 MiB of P4 flash were backed up and
verified. After the test, the original P4 bootloader and app were restored and
the entire flash was verified against that backup. The RTC was intentionally
left updated. The C6 firmware was not rolled back by this P4 restoration.

This observation is a single short run, not evidence of cold-power RTC
retention, network interruption/recovery, long-term drift, or reduced P4 load.
The physical candidate corresponds to the commit above; subsequent
report-only changes do not change its source or binary.
