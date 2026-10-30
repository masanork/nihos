# Canvas scanout fixture

Experimental opt-in device fixture; it is not the application-facing display service. With `NIHOS_NATIVE_CANVAS_DEMO=1`, the existing display owner paints a diagnostic color pattern into its private 720×1280 RGB565 PSRAM framebuffer using Canvas before scanout begins. A black-and-white stripe uses the RGB565 row-copy path. The existing cache writeback and DMA/DSI startup publish that frame. There is no runtime canvas lease, concurrent rendering, present API, input, card data, or live scene change. The fixture bypasses the boot animation and stays separate from the console and card paths.

Build using the pinned SDK and Zig:

```sh
NIHOS_NATIVE_CANVAS_DEMO=1 NIHOS_NATIVE_DISPLAY=2 NIHOS_NATIVE_PSRAM_200=1 \
NIHOS_NATIVE_QUALIFICATION=1 NIHOS_NATIVE_CONSOLE=0 NIHOS_NATIVE_NETWORK=0 \
NIHOS_NATIVE_DEVICES=0 sh tools/build-native.sh device integer
```

The explicit profile rejects other display modes and device fixtures. The fixture uses physical portrait coordinates and reports 720×1280, rotation 0. Before scanout, it checks FNV-1a of the complete visible frame (`549e3481`) and fails startup if it differs; after successful startup it emits `NIHOS_NATIVE_CANVAS_PATTERN`. The display-log checker supports this profile with `--mode 2 --dpi 80 --canvas-demo`, requiring the portrait layout, matching checksum and frame count, subsequent healthy IRQ, and existing native memory/display checks. Its tests reject absent, duplicated, out-of-order or wrong records. The checksum detects accidental deviations in the CPU framebuffer; it is not cryptographic verification and does not check pixels after DMA or establish optical correctness.

`python3 tools/prepare_canvas_candidate.py build/native-device build/native-device/canvas-candidate.json` validates the options, app and ELF against the image audit, the embedded fixture marker, and hashes all installation artifacts. This is local artifact consistency only, not a device receipt or proof that the current source built the image. Recheck exact bytes under the device lease immediately before capture; a receipt does not authorize reuse after a rebuild.

Before physical testing, identify the board and current firmware/partition layout, coordinate a single write owner as well as verified kernel-exclusive serial access, back up the affected Flash, and prepare restore plus byte verification. Do not change SD or unrelated partitions. Retain the raw and normalized logs, the exact candidate artifacts, verification and restoration receipts, and note whether the reset was warm or cold. The host test checks the checksum, a one-byte negative control, representative color pixels, invalid geometry, and padding. Build/image audit and host tests do not establish physical scanout, color correctness, latency or optical quality. The drawn pattern is a diagnostic, not a proposed UI design.

`tools/capture_canvas_fixture.py` prepares a private 16 MiB backup, checks that the partition table matches, writes only bootloader and factory app, verifies the candidate before capture, validates the log, then restores the erase-aligned original spans and verifies the entire Flash backup. The tool records restore failures and avoids an explicit reset when restoration does not verify. It enforces a cooperative writer lock, serial exclusive open and kernel alias exclusion. These do not independently prevent a writer using another hardware interface; coordinate device-wide ownership separately. Its failure-path and span tests are host models and do not prove that a particular device or backup can be restored.
