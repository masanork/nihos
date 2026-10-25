# Tab5 bounded touch bootstrap

- Date: 2026-10-25
- Evidence: physical M5Stack Tab5, ESP-IDF-hosted firmware
- ABI: nihOS platform ABI version 3
- Driver source: pinned official NoGLIB BSP and ESP LCD touch components

The touch boundary exposes only display-space dimensions, a fixed maximum of
five points, monotonically increasing sample sequence numbers, and fixed-width
point fields. ESP-IDF and controller-specific handles stay inside the C
bring-up backend. Initialization is rejected until the display is running
because ST712x combines the panel and touch controller.

On each of three consecutive boots, the physical device initialized the
panel-matched touch driver and completed eight I2C polls separated by display
refreshes:

```text
touch_width=720
touch_height=1280
touch_max_points=5
touch_samples=8
touch_points_observed=0
touch_sampling=ok
nihos: bootstrap complete
```

The device was deliberately not touched, so this proves controller
initialization, communication, empty-snapshot handling, and repeatable
display-plus-touch startup. It does not qualify pressed coordinates,
orientation, tracking IDs, strength, latency, or multi-touch behavior.

Linking the touch polling path increased the application image from 346,112
bytes (`0x54800`) to 358,320 bytes (`0x577b0`). The 1 MiB application partition
has 690,256 bytes (66%) free. The final ESP-IDF size report contains 195,926
bytes of Flash text, 87,076 bytes of Flash read-only data, and 81,341 bytes of
DIRAM.

The next physical touch gate needs a human interaction trace covering corners,
centre, press/release, two fingers, and coordinate orientation. Until then,
the implementation is an idle-poll bring-up result rather than a qualified
input device.
