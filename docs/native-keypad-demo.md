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

Sparse scanout uses fixed SRAM colours for blank areas and PSRAM only for
text pixels. The host test replays the same immutable plan for all counts
0–4 and compares it byte-for-byte with the real renderer. The current plan
contains 637 64-byte descriptors (40,768 bytes). Each CPU allocates a slab
from its own arena after qualification; CPU1 publishes its permanent DMA
lease, then parks. CPU0 never updates CPU1's allocator. Both leases are
checked against the recorded owner boundaries. The existing 48 KiB heap
floor and stack reservations are unchanged.

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
python3 tools/boot-graphics/preview-card-pin.py --demo --out build/keypad-demo-preview
python tools/capture-native-usb.py PORT OUTPUT build/native-device/image-audit.json \
  --install build/native-device --keypad --runs 1
```

This is a count-only demonstration. It does not qualify an authenticated
card read, certificate verification, long-running application scheduling,
or simultaneous filesystem traffic.
