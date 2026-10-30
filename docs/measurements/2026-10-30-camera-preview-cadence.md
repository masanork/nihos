# Camera preview cadence (2026-10-30)

Normal-profile camera updates improved from a mean 2.366 seconds to 0.209 seconds, about 11.3 times faster (approximately 4.8 updates per second). This is still an 80×45 grayscale sample enlarged to 320×180, produced by repeated finite 1280×720 RAW8 captures. It is not continuous DMA or a measured video frame rate.

| Candidate | Automatic updates | Measured intervals | Mean interval | Range |
| --- | ---: | ---: | ---: | ---: |
| Previous normal prototype, `86d2fcf` | 5 | 4 | 2.366 s | 2.283–2.446 s |
| Optimized `dedb743`, first run | 60 | 59 | 0.209 s | 0.193–0.236 s |
| Same optimized image, independent second run | 60 | 59 | 0.210 s | 0.198–0.240 s |

Intervals use host monotonic timestamps when complete snapshot UART records arrive; they exclude first-frame startup. Both successful optimized runs used app SHA-256 `14721f092c032a49a124eaa1956debf64f099756d799ab52f41b62dec8fc6bbd` on Tab5 ESP32-P4 revision 1.3, MAC `e8:f6:0a:e2:e8:9c`. The source was clean when frozen. [Comparison data and identities](evidence/2026-10-30-camera-preview-cadence/comparison.json) retain the intervals, image/ELF/loader hashes, source identities and restoration receipts without scene pixels or credentials.

## Changes

The previous implementation spread approximately 130 sensor register writes, frame cache preparation and 90 sampled-row reads over 10 ms foreground iterations. Normal preview now batches work with iteration caps and elapsed-time checks between operations. A cleanly stopped sensor keeps its configuration while snapshots continue; after 500 ms without another capture, the owner powers the sensor and XCLK down. The existing sensor delays, DMA stop observation, two-pass sample comparison and framebuffer verification remain. Diagnostic profiles retain their original cadence.

The same frame/channel lease stays pinned until reset. No second capture buffer was introduced. The resulting SRAM heap span is 51,264 bytes, above the unchanged 49,152-byte floor; this span is not measured free application memory.

## Defects exposed by faster updates

An early optimized run completed 20 updates, then failed while dismissing the preview. Full shell repaint is now deferred until the outstanding capture drains. A host regression covers the deferred repaint transition. The successful optimized trials each discarded pending captures 61 and 63, completed manual snapshots 62 and 64, repainted the shell three times, and returned to its memory command. Snapshot 64 followed a one-second idle period, exercising capture after idle power-down.

Longer trials also exposed a sensor stream-control data NACK (`reason=0x804`), including one after 57 updates. Stream-on/off now masks CPU0 interrupts across the short synchronous SCCB write/readback pair; failed transactions still reject capture. Other bulk setup and sampling keep their bounded foreground scheduling. The two successful 60-update runs followed this change. These finite runs do not establish the electrical cause of the NACK or qualify worst-case interrupt latency.

Each successful run presented 62 images with zero sampled-preview framebuffer mismatches and 60 distinct automatic-update hashes. Network-service heartbeat records appeared, but Wi-Fi was unconfigured. The normal filesystem attempted a read and rejected the current volume with error -262; communication, mounting and SD reads are not qualified by this trial.

All trials verified the exact candidate before capture. Successful trials verified it afterward, restored both original flash erase spans, checked complete readback and issued a hard reset. The restored system's boot was not captured. A separate session's font/store firmware and data were preserved; shared write ownership and kernel serial exclusivity were held during camera trials.

Optical panel appearance, physical keyboard/touch operation, cold power-on, sustained capture and continuous DMA/video remain unqualified. Frozen artifacts and raw logs remain in the private directories named in the comparison data. The private qualifier is `/private/tmp/nihos-camera-fast-tools/tools/qualify-camera-id.py`.

Main integration also exposed initialization lint errors in the newly added, unwired XY modules. Their empty-buffer initialization was made explicit without adding bitmap-cache clearing on cache misses; the three-file correction passed the full 921-test Debug suite and static analysis in isolation.
