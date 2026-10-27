# Boot graphics: 素のハードウェアを、色づける。

The first screen is monochrome on an ink-black background. The three `丹穂`
pairs gradually take on vermilion in reading order, connecting the name
**nihos / にほす** to the sense of giving colour. Five vertical columns read
from right to left; the subtitle explicitly says `にほす ─ 色づける`.

The user-supplied inscription is preserved exactly:

> 墨之江之岸野之榛丹丹穂所経迹丹穂葉寐我八丹穂氷而将居

The source is **万葉集 巻十六・3801**, not 古事記. The text and attribution
can be checked against the [Nara Prefecture Manyo Culture Museum database](https://manyo-hyakka.pref.nara.jp/db/detailLink?cls=db_manyo&pkey=3801).
This is a visual treatment of the project's naming idea, not a claim that
every `丹穂` occurrence is the same grammatical form of `にほす`.

## Runtime and integration

`src/graphics/boot_graphics.zig` is a pure, allocation-free RGB565-LE renderer.
It needs a writable surface of at least 720×1280 and a valid stride. Larger
surfaces center the inscription; smaller ones are rejected before any write.
No filesystem, storage device, dynamic font engine, OS clock, or scheduler
is needed. The [embedded lettering](../src/graphics/boot/README.md) is licensed
separately from the renderer and adds 28,366 bytes of compressed masks.

The existing **ESP-IDF-hosted** entry now initializes the panel immediately
after ABI validation and boot-fact logging, before memory and CPU smoke tests.
It paints before the existing platform present call enables the backlight.
The existing single scanout buffer is reused, without a second framebuffer.
The diagnostics test-pattern renderer remains available as a separate module.

Visible stages follow actual calls: `DISPLAY`, `MEMORY`, `CORES`, `INPUT`,
then `READY` only after touch sampling succeeds. An early return after display
initialization attempts to leave `FAILED - SEE SERIAL` on screen. A trap or
hang that never returns leaves the last stage visible; the renderer is not
an independent watchdog. If panel initialization itself fails, serial is the
available diagnostic path.

The colour value is aesthetic, not a percentage. Memory completion reveals
the first pair; CPU checks reveal more colour. Sixteen presents finish the
fade before input checks, without a timed sleep or minimum splash hold. Those
presents do add rendering/refresh work. The 60-sample VSYNC measurement stays
separate from animation so its wait timings are not mixed with rendering.
The preview's timing and stage transitions are illustrative.

The **independent native path** now has its own opt-in DSI/PSRAM scanout;
see [native display evidence](native-display.md). Its default graphic experiment
still runs after native qualification with an aesthetic hold/fade. The optional
[native console](native-console.md) can instead start video before core
qualification, drive colour from actual milestones, and switch to logs through
the standard I2C keyboard or diagnostic serial controls. Its
[device records](measurements/2026-10-27-native-console-live.md) distinguish
normal boot, injected failure, serial controls and pending optical/physical-key
confirmation. Do not infer native boot order from the hosted sequence above.

## Preview and checks

The opt-in USB/card fixtures are separate from normal splash/console boot.
`DISPLAY=8` starts the keypad demonstration; `DISPLAY=9/10/11` starts the
selected card screen directly. Their never-visible preparation framebuffer is
cleared instead of embedding the normal splash alongside the card fonts.
Normal `DISPLAY=2` with live console retains its splash and boot-stage flow.
See the [card integration record](measurements/2026-10-27-card-main-landing.md)
for source/build evidence and the pending physical gates.

```sh
.tools/zig-0.17.0/zig build test
.tools/zig-0.17.0/zig build test -Doptimize=ReleaseSafe
python3 tools/boot-graphics/preview.py
sh tools/build-espidf.sh
```

The preview builds the actual Zig renderer as a host library, then exports
`build/boot-graphics/preview.html` (self-contained replay), `preview.gif`,
`preview.png` (three stages), and `ready.png`. Python with Pillow is needed
only for generation/preview. Tests check mask bounds, guard bytes, padded
strides, rejected overflow, fade order, and that only the intended pairs and
state marker change colour.

The original hosted-only verification below predates native scanout work.
Current native qualification and its remaining optical gates are linked above;
tearing, colour and perceived animation latency require direct observation.

Local verification on 2026-10-26: 104/104 host tests pass in both Debug and
ReleaseSafe; Zig formatting and ZLint pass with zero warnings. The ESP-IDF
v5.4.4 ESP32-P4 firmware build succeeds (`nihos.bin`: `0x71ce0` bytes), fitting
the existing 1 MiB application partition. The PNG stages and final portrait
were visually inspected. These are host/build results, not device results.
