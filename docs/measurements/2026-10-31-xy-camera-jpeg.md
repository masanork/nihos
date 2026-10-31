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

## Current validation and remaining gate

The pre-rebase physical JPEG candidate `19311dd` produced a **53,791-byte, 1280×720 RGB JPEG**. The encode setup-to-completion observation was **16.671 ms**, including foreground polling latency. All bytes were reconstructed solely from Scheme `camera/read` replies, matched the completed codec FNV, and fully entropy-decoded with Pillow. Unissued/wrong handles, second capture, pending read and invalid ranges were rejected; EOF and post-transfer editing/undo passed. Candidate bytes were verified before/after capture, and both original flash spans were restored with full readback.

The serial/minibuffer qualification took 174.9 seconds. This deliberately small-copy API/diagnostic transport check is not application transfer throughput or video FPS. The final trace's transmit-drop observations were all zero. Earlier tests exposed repeated state echoes and lost/truncated USB records: the verifier now deduplicates by evaluation revision, and explicit XY trace builds allow a longer bounded host scheduling pause while reporting transmit drops. Ordinary builds retain the existing short best-effort transmit budget. Capture now has a 20-second deadline before readiness, plus trace-only phase telemetry.

Debug and ReleaseSafe each passed all 61 build steps. All 508 Python tests, static analysis/six native links, uninstrumented default/XY-JPEG builds and ordinary-FS identity negative controls passed. The connected XY trace candidate passed editing, undo, IVS deletion, help/system views, Scheme error recovery and unavailable camera calls, but the subsequent warm-reset/ROM connection failed. Automatic restoration also failed because the device stopped responding. Its `RESTORE_FAILED` marker and both private backups remain retained. The complete backup hashes match the independently restored earlier baseline trial. The user explicitly waived restoration on 2026-10-31 and requested rebasing, CI fixes and landing PR #88. No further device writes or recovery are required for this landing. The backups and failure marker remain historical evidence; restoration is not claimed, and this later connected trace trial is not counted as qualified.

[Summary and identities](evidence/2026-10-31-xy-camera-jpeg/summary.json) retain exact source/image/ELF/serial identities and the qualified JPEG restoration receipt. Scene images and scene-derived UART data remain private. General DMA retirement, repeated capture, calibrated color/exposure, cold power, panel pixels and continuous video remain unqualified.

## Rebase and landing scope

PR #88 is rebased onto the current main, including the native XY pixel renderer, Scheme view configuration, dedicated evaluation/render stacks and the 25-minute host quality timeout. The physical results above name the original frozen pre-rebase candidates. Validation of the rebased source uses host tests, image audits and CI; no new physical-device, warm-reset or restoration success is inferred from it.
