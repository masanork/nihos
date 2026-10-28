# Canvas scanout fixture

Experimental opt-in device fixture; it is not the application-facing display service. With `NIHOS_NATIVE_CANVAS_DEMO=1`, the existing display owner paints a diagnostic color pattern into its private 720×1280 RGB565 PSRAM framebuffer using Canvas before scanout begins. The existing cache writeback and DMA/DSI startup publish that frame. There is no runtime canvas lease, concurrent rendering, present API, input, card data, or live scene change. The fixture bypasses the boot animation and stays separate from the console and card paths.

Build using the pinned SDK and Zig:

```sh
NIHOS_NATIVE_CANVAS_DEMO=1 NIHOS_NATIVE_DISPLAY=2 NIHOS_NATIVE_PSRAM_200=1 \
NIHOS_NATIVE_QUALIFICATION=1 NIHOS_NATIVE_CONSOLE=0 NIHOS_NATIVE_NETWORK=0 \
NIHOS_NATIVE_DEVICES=0 sh tools/build-native.sh device integer
```

The explicit profile rejects other display modes and device fixtures. The host test checks representative color pixels, invalid geometry, and padding. Build/image audit and host tests do not establish physical scanout, color correctness, latency or optical quality. Physical tests require exclusive device and write ownership, exact image identification and byte verification, plus a separate optical observation. The drawn pattern is a diagnostic, not a proposed UI design.
