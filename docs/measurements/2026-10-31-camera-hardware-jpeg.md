# Native hardware JPEG proof (2026-10-31)

The opt-in ESP32-P4 fixture encoded both known RGB565 color bars and a real SC2356/SC202CS camera frame into 1280×720 color JPEGs, which Pillow fully decoded on the host. The final camera JPEG was 42,876 bytes with quality 75 and 4:2:2 subsampling. The observed setup-to-completion time was 23.457 ms, including foreground polling latency; this is not a measured continuous video rate.

| Trial | Synthetic bars | Camera JPEG | Camera encode observation | Host decode |
| --- | ---: | ---: | ---: | --- |
| Initial candidate `5b3c86d` | 21,522 bytes | 36,545 bytes | 19.335 ms | Both 1280×720 RGB |
| Cache-handoff candidate `0a4fd88` | 21,522 bytes | 37,209 bytes | 19.115 ms | Both 1280×720 RGB |
| Final ownership-guard candidate `98b8088` | 21,522 bytes | 42,876 bytes | 23.457 ms | Both 1280×720 RGB |

The final app SHA-256 is `76ec8168c2d3497eb298f2ca2f45a22c1e84241e54076f92e9522d4f4b661acc`. All three JPEG trials used Tab5 ESP32-P4 revision 1.3, MAC `e8:f6:0a:e2:e8:9c`, with clean frozen source. [Measurements and identities](evidence/2026-10-31-camera-jpeg/summary.json) retain image/ELF/loader/source/log hashes, compression records, memory counters and restoration receipts. Real camera images and their scene-derived UART data remain private in the named trial directories.

## Hardware path and checks

The fixture runs known bars first. It then zeros and cleans the same source allocation, requests one finite camera capture, and waits for stopped CSI/DW-GDMA and completed sensor/ISP cleanup before reading the RGB565 frame. The ISP performs Bayer demosaic and color conversion in hardware. The JPEG codec and its separate DMA2D controller encode the RGB565 source. Software emits only a fixed baseline JPEG header and quantization tables; the accelerator generates the entire entropy-coded payload and EOI marker.

The public [hardware-encoded bars JPEG](evidence/2026-10-31-camera-jpeg/pattern.jpg) has SHA-256 `9df9069c2c78683da14d7589658162de1fda46f556deff81e443733917457a77` in all three independent trials. The host fully entropy-decodes both files, checks geometry and RGB mode, and checks all eight bar centers at three heights against expected RGB565 colors within a 12-level JPEG tolerance. Each camera source checksum and JPEG differs from the known bars. UART data are bounded chunks with consecutive offsets and a final checksum; the saved files must exactly equal the reconstructed stream. Checksummed transfer alone is not substituted for image decoding.

The fixture owns its workspace and rejects ordinary camera commands while active. The final physical trial explicitly sent snapshot and live-preview requests during pattern export: both were rejected (`kind=26/30`, `accepted=0`), and the owned camera capture then completed normally.

The final candidate masks CPU0 interrupts around JPEG cache handoff so the display ISR cannot nest ROM cache operations. Source payloads are cleaned before DMA reads, output/descriptor memory is prepared before device writes, and returned descriptor/payload data is invalidated before CPU consumption. JPEG/DMA2D admission rejects pre-existing clocks/owners. The fixture uses polled raw status, retains every payload/descriptor until reset and stops on DMA/codec faults, output exhaustion or a five-second completion deadline. Successful output requires RX EOF, idle TX/RX and descriptor state, CPU ownership, no descriptor error and an in-range length. This does not establish general DMA2D retirement or sharing with PPA/another codec user.

## Memory and normal-build regression

The fixture reserves one 4 MiB PSRAM block containing the 1,843,200-byte RGB565 source and an equally bounded JPEG output area, plus 4 KiB capture scratch. The final `mem` report measured capacity 15,072,576 bytes, free 10,874,176, used 4,198,400. Both compressions reuse that block. The small resulting JPEG does not imply a similarly small working-memory requirement. Allocations and accelerator ownership remain retained until reset; output sizing, on-demand release and power-down are follow-up work.

Networking and normal FS are disabled for this isolated fixture to fit existing resident/Flash budgets without enlarging them. The SRAM heap span is 76,352 bytes for the final fixture. The default connected build leaves JPEG off and retains its 50,496-byte heap span and prior camera allocation policy. A separately flashed default candidate completed 61 live updates, visible stop, manual capture, loading cancellation, idle-to-cold capture and the shell memory command, with zero framebuffer mismatches and about 17.27 updates/s. Its exact image/ELF/serial identities and restoration receipt are in the summary. No camera-JPEG/connected-network coexistence is claimed.

All device trials held the shared board-writer lease and kernel serial exclusion, verified candidate bytes before and after capture, backed up both affected flash erase spans and restored them with full readback before hard reset. The restored system's boot was not captured. Write ownership was released afterward; original XY/font/host edits were preserved in their checkout.

## Reproduce

Build the fixture with `NIHOS_NATIVE_NETWORK=0 NIHOS_NATIVE_NORMAL_STORAGE=0 NIHOS_NATIVE_CAMERA_JPEG=1 sh tools/build-native.sh device`. It writes `build/native-device-devices-camera-jpeg/`. The default `sh tools/build-native.sh device` continues to produce the normal connected camera image. CI builds and audits the opt-in fixture as an additional native configuration, without claiming hardware execution.

Use `python3 tools/native_jpeg.py /private/tmp/nihos-camera-jpeg-final-20261031` to reconstruct/check the private UART evidence and fully decode both JPEGs (requires Pillow). The private qualification wrapper and capture driver are under `/private/tmp/nihos-camera-jpeg-tools/`; the flash transaction still performs identity-checked backup and verified restoration. The public synthetic JPEG can be opened in any standard JPEG viewer. Host tests exercise missing/duplicated/corrupted payloads, invalid dimensions/timing, incomplete workflows and the public artifact's identity and baseline geometry.

Debug and ReleaseSafe host suites each passed 921 tests. Static analysis, six native ELF audit links, default and JPEG-profile image audits, and the ordinary FS identity check with five negative controls passed. The final Python suite passed 504 tests. The initial Python run exposed stale font/atlas source witnesses after the main-loop hook; these were regenerated canonically with unchanged payloads.

## Provenance and limits

Register sequencing follows ESP-IDF v5.4.4 commit `296b6eab9445fd720e71aecab961e2d3fbca9944`: `esp_driver_jpeg/jpeg_encode.c`, `esp_hw_support/dma/dma2d.c`, `hal/jpeg_hal.c`, and the JPEG/DMA2D LL headers (Espressif Systems, Apache-2.0). `tools/generate-native-jpeg-fixture.py` generates the fixed 720p/Q75 header and natural-order quantizers using Pillow 11.3.0; it does not generate firmware entropy-coded image data.

This is a finite hardware encode/decode proof. JPEG saving through the normal filesystem, XY APIs, continuous JPEG/video, full default-connectivity integration, calibrated color/white balance/exposure, optical panel display, cold power and long-duration operation remain unimplemented or unqualified. The captured scene was dark; its compressed size is not a prediction for arbitrary scenes or quality settings.
