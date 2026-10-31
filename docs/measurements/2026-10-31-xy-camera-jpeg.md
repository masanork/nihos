# XY single-shot hardware JPEG access (2026-10-31)

The opt-in XY camera build connects the bounded Scheme runtime to the existing native ISP/JPEG service. It waits for an explicit request and retains one immutable JPEG until reset. The ordinary connected XY build reports `Camera unavailable` and does not allocate camera memory for these calls.

In XY, press Esc to enter the minibuffer, evaluate one expression, and press Enter:

```scheme
(define image (camera/capture!)) image
(camera/info image)
(camera/read image 0 32)
```

Capture returns an opaque positive integer handle. Info returns `(pending 1280 720 0)`, `(ready 1280 720 byte-count)` or `(failed 1280 720 0)`. Read returns a hexadecimal string containing 0–32 copied bytes, so JPEG binary data cannot act as editor input. A zero-length read at EOF is valid. Negative offsets/counts, larger reads, invalid handles, pre-completion reads and ranges beyond the actual compressed length are rejected. The document and undo history are unaffected.

Only one handle is issued per boot. Another capture reports `Camera busy`, including after completion; reset the board to capture again. Resetting the Scheme VM does not release or replace the camera frame. The source, output and DMA descriptors remain pinned until device reset, including on failure. No raw pointer, borrowed DMA slice, general resource retirement or filesystem write is exposed.

Build this explicit profile:

```sh
NIHOS_NATIVE_CAMERA_ID=1 NIHOS_NATIVE_CAMERA_DIAGNOSTICS=0 \
  NIHOS_NATIVE_CAMERA_JPEG=1 NIHOS_NATIVE_XY_WORKSPACE=1 \
  NIHOS_NATIVE_NETWORK=0 NIHOS_NATIVE_NORMAL_STORAGE=0 \
  sh tools/build-native.sh device
```

For bounded qualification, also set `NIHOS_NATIVE_XY_TRACE=1`. The trace includes hex-encoded Scheme replies and a completed-JPEG length/FNV record. `tools/xy_camera.py` reads the image entirely through Scheme `camera/read` replies, verifies that the bytes match the codec's completed output, and fully decodes the saved JPEG with Pillow. Its caller must provide already verified exclusive serial ownership and flash backup/restore; the collector itself never flashes. Real scene bytes and UART traces must remain in a private output directory.

The service uses the same 4 MiB pinned source/output allocation and 4 KiB scratch as the [hardware JPEG proof](2026-10-31-camera-hardware-jpeg.md). Networking and ordinary filesystem services are disabled in this profile; connected camera/JPEG coexistence is not established. Color/exposure calibration, an image viewer, SD saving, continuous JPEG and repeated capture without reboot remain follow-ups.
