# Continuous camera preview (2026-10-31)

Normal `camera-live` now keeps the SC202CS sensor, CSI bridge and ISP running and rearms DW-GDMA channel 1 on completion. Two finite trials on Tab5 measured 17.18 and 17.58 displayed updates per second, approximately 3.6 times the previous repeated-snapshot implementation. The preview remains an 80×45 grayscale sample enlarged to 320×180 from 1280×720 RAW8; this does not establish full-resolution video throughput or optical quality.

| Same final image | Presented live updates | Mean interval | Interval range | Stop to drain |
| --- | ---: | ---: | ---: | ---: |
| First run | 61 | 58.20 ms | 41.04–78.35 ms | 284.62 ms |
| Independent second run | 61 | 56.87 ms | 47.26–70.69 ms | 262.42 ms |

Each trial requested dismissal after update 60. The shell's 30 ms Escape decoder allowed one additional update before recognizing dismissal. Neither trial presented an image after its drain record. Intervals are host monotonic timestamps at receipt of complete snapshot UART records, exclude first-frame startup, and include UART/logging overhead. Each live segment lasted about 3.5 seconds; these are finite regressions, not prolonged streaming qualification.

Both runs used clean source `a95a5eafe50c838f733a0eddbedd307fd972dbeb`, app SHA-256 `df5aeeca21f8aaf7977d0afdfbc7e853c4de6dadb0e4bde2ac2ac45e5776b805`, and ESP32-P4 revision 1.3, MAC `e8:f6:0a:e2:e8:9c`. [Comparison data](evidence/2026-10-31-camera-continuous/comparison.json) retain image/ELF/loader and raw-log identities, intervals, stream counters, memory measurements and restoration receipts. Scene pixels and credentials are excluded.

## Ownership and memory

The shared display DW-GDMA handler services channel 1 completion without resetting the controller or clearing channel 0 events. A CPU0-serialized two-slot pool publishes a completed buffer with a generation number. Foreground sampling borrows that inactive slot and invalidates its sampled cache lines; the IRQ repeatedly uses the other slot until release, dropping incoming frames instead of overwriting the reader. The CPU never modifies either payload after its initial clean handoff. A separate stable scratch copy supplies display painting. The existing two-pass comparison and framebuffer verification remain enabled.

The first normal camera use allocates both 921,600-byte payloads in one pinned allocation. Its buddy reservation is 2,097,152 bytes; scratch occupies another 4,096 bytes. This increases the frame reservation by 1 MiB compared with the previous single-buffer version, including for an initial `camera` snapshot. It consumes one frame allocation ledger entry rather than exceeding the task's two-entry frame-plus-scratch limit. Both payloads and the channel remain retained until reset; no general resource retirement is claimed.

After each workflow, `mem` reported reusable PSRAM capacity 15,072,576 bytes, free 12,971,328 and used 2,101,248. These are that heap's measurements, not total board RAM or application capacity. The audited SRAM heap span is 50,624 bytes above the unchanged 49,152-byte floor; this is reservation space, not measured free SRAM. Booting the launcher alone does not request the camera allocations.

## Stop, restart and faults

Stop requests prevent new borrows and rearming after the next completed transfer. Foreground cleanup then performs sensor-off, DMA stop observation, ISP/CSI stop, and finally shell repaint. Starting another live session retains generation identity so stale releases cannot free a newly borrowed buffer. A five-second progress watchdog, DMA/controller/bridge faults and preview comparison errors stop rearming and retain resources through the existing pinned failure path.

The trials each completed live dismissal, manual capture, dismissal while the next live view was still loading, a one-second idle interval followed by another manual capture, and the shell memory command. Each presented 63 images with zero sampled-preview framebuffer mismatches and repainted the shell three times. The live stream counters were 107 completions / 45 drops and 104 / 43; both reported zero faults. Loading-stage cancellation reported zero completed frames and zero faults. Network service heartbeat records appeared while Wi-Fi was unconfigured. Filesystem read attempts still rejected the current volume with error -262; SD reads and configured network traffic are separate gates.

An early candidate failed before DMA because a separately pinned second frame exceeded the task allocation ledger. The final allocation contains both frames. Another candidate displayed correctly but failed stop because the stream-end check read a clock-gated CSI bridge; the final check follows the clock guard already used by retained snapshot restart. The qualifier was also corrected to accept frames before Escape recognition while still rejecting all frames after drain.

Debug and ReleaseSafe host suites each passed 921 tests, the Python suite passed 490, static analysis and native image/source identity audits passed, and the production C register replay covers DMA rearm, reader protection across repeated drops, stale releases, cross-session generations, gated-clock shutdown, invalid buffer ranges and a shared-controller fault. The newly integrated XY C-ABI host source also needed initialization/style corrections for static checks; byte-color extraction keeps its original eight-bit semantics, and the shared library compiles in ReleaseSafe.

Trials held shared write ownership and kernel serial exclusivity, froze the exact source/image, and verified candidate bytes before and after capture. Both original flash spans were restored and checked by full readback before hard reset; the restored system's boot was not recorded. Frozen artifacts and the qualifier path/hash are in the comparison data. Reproduce the candidate with `sh tools/build-native.sh device` using ESP-IDF v5.4.4; validate its source identity with `python3 tools/check-normal-native.py build/native-device-network-devices-camera`. Run the production register replays with `NIHOS_CSI_SDKCONFIG_DIR="$PWD/build/native-device-network-devices-camera/loader/config" sh tools/run-csi-preflight-replay.sh`.

Optical appearance, physical keyboard/touch input, cold power-on, long-running capture, color/full-resolution video and concurrent configured Wi-Fi/SD throughput remain unqualified.
