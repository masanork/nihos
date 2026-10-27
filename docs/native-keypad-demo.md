# Native keypad operation demo

Build with `NIHOS_NATIVE_DISPLAY=8 sh tools/build-native.sh device integer`.
USB/JPKI/CARD_CHECK are rejected. The screen states that arbitrary numbers
are for operation testing and that nothing is sent to a card. The model stores
only a 0–4 count. UART events contain effects and counts, never key identities
or touch coordinates. No PIN buffer or card service is instantiated.

The full-size screen uses full-width key rows and four masked indicators.
Digits, erase, cancel and confirmation activate once on explicit release.
Holds, drags outside a key and multiple simultaneous contacts disarm a press.
The touch sample's unchanged state never commits an action.

Sparse scanout uses fixed SRAM colours for blank areas and SRAM for every
pixel consumed by DMA. Generated immutable lettering (203,144 bytes) is
stored in read-only, non-executable Flash and copied once at startup.
The host test replays the baked plan for all counts 0–4 and compares it
byte-for-byte with the real renderer. The plan contains 637 64-byte DMA
descriptors (40,768 bytes). Two dedicated RW, non-executable NOBITS pools
use 0x4ff40000–0x4ff60000 and 0x4ff70000–0x4ff9f000. These are inside the
pinned SDK's early-silicon high SRAM window, outside the separate stack
span, ROM reservations and L2 cache. The low pool holds double-buffered
dynamic textures, descriptors and overflow lettering; the high pool holds
most immutable lettering. The image auditor rejects other profiles,
unapproved pools, mutable/executable Flash assets, asset hash changes and
stale generator inputs. The existing 48 KiB heap floor and stack
reservations are unchanged. This demo reserves these pools exclusively;
it does not provide a general-purpose allocator for them.

Only indicator/confirmation textures change during interaction. The CPU
draws into the inactive small buffer, synchronizes caches with local IRQs
masked, then publishes it. The display IRQ swaps texture sources and the
confirmation fill at the frame boundary before rearming the descriptors.
It never rewrites the full framebuffer while DMA reads it.

The keypad probe publishes a checkpoint after counts 0–4 have each survived
a frame and erase, cancel and confirmation have been exercised, or after
120 seconds. The screen remains interactive afterwards. A timeout with
incomplete coverage is rejected by the evidence checker. Optical visibility
must still be confirmed by the user.

```sh
python3 tools/boot-graphics/generate-keypad-atlas.py
python3 tools/boot-graphics/preview-card-pin.py --demo --out build/keypad-demo-preview
python tools/capture-native-usb.py PORT OUTPUT build/native-device/image-audit.json \
  --install build/native-device --keypad --runs 1
```

This is a count-only demonstration. It does not qualify an authenticated
card read, certificate verification, long-running application scheduling,
or simultaneous filesystem traffic.
