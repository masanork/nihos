# ADR 0049: Finite native Tab5 audio-output probe

- Date: 2026-10-28 JST
- Status: local qualification candidate; not normal/default audio support
- Based on main `734e89e`, after native BMI270 integration

## First output boundary

The first native audio path is an explicitly selected, finite output fixture:
`NIHOS_NATIVE_AUDIO=1 sh tools/build-native.sh device`. Normal builds keep audio
disabled. Only the normal integer device boot/display profile accepts this
option; emulator and card/qualification profiles cannot silently enable sound.
Artifacts use a separate `native-device[-network]-audio` output directory.

The fixture requests one quiet diagnostic tone ten seconds after normal boot.
It configures ES8388 for 16-bit Philips I2S DAC playback, nominal 16 kHz stereo,
and uses I2S0 with AHB-DMA TX0. GPIO30/27/29/26 carry MCLK/BCLK/LRCK/data.
GPIO28 and the ES7210 microphone ADC are untouched. No microphone capture,
mixing, file/media decoding, streaming refill or application audio ABI is added.

ESP32-P4 rev1.3 does not support I2S's PLL160 source. The fixed divider uses
XTAL40M / (9 + 49/64) = 4.096 MHz MCLK; MCLK/BCLK=8 and 32 BCLK/frame give a
nominal 16 kHz frame rate. This configuration calculation does not qualify the
actual pin clock frequency or analog sound.

## Device and memory ownership

The existing CPU0 board-I2C owner supplies all ES8388 and amplifier transfers.
The amplifier is first disabled through a masked P1 update on expander 0x43;
LCD/touch and other output bits are preserved. Codec configuration reads back
documented writable fields and preserves reserved bits. The DAC stays muted
through analog settling and only unmutes after a successful I2S/DMA start.

PCM is bounded to 1 KiB of 64-byte-aligned internal SRAM, with 32 separately
linked 16-byte descriptor slots occupying 512 bytes. All slots refer to that
immutable waveform block and the final next pointer is null. Total nominal
output is 8192 frames / 512 ms. Both stereo channels carry the same waveform,
whose peak is 1024/32768, followed by -12 dB DAC attenuation. This is a low-level
diagnostic sound, not a calibrated sine source or a volume guarantee.

AHB-DMA's common memory-range setup is exclusive to this boot fixture. It
rejects pre-existing RX/TX clients and never resets an active channel to obtain
ownership. I2S0 register update and DMA-stop handshakes have finite poll limits.
The fixture does not claim a general DMA resource allocator or concurrent
application ownership protocol.

DMA total EOF must identify the last descriptor and show nonzero I2S clock
progress. A short drain interval separates DMA completion from analog shutdown.
Shutdown attempts amp-off/mute and DMA stop independently. Only confirmed DMA
quiescence and cache/descriptor ownership return permit a returned-buffer
receipt; failures retain the static buffers and cannot start another request.
No timeout alone authorizes reuse. Sensor/display/network polling continues
outside the bounded setup and shutdown operations.

## Evidence

`NIHOS_NATIVE_AUDIO` distinguishes idle, setup, playing, draining, stopped and
failed phases. `NIHOS_NATIVE_AUDIO_IO` retains the first failed I2C operation,
including expected/actual readback. Phase markers identify native preparation
steps; trap reports include `mtval` so a bad data address is not confused with
the later trap-prologue PC.

Host tests cover finite descriptor construction, raw PCM bounds, stereo
matching, data/descriptor alias rejection, analog configuration readback,
reserved-bit preservation, start-before-unmute, drain time, and independent
cleanup after clock/start/DMA/I2C failures. They cannot prove clocks, actual
DMA handshakes, speaker output, absence of clicks or microphone behavior.

Exact candidate hashes, retained failures and physical boundaries belong in the
measurement checkpoint. Audible confirmation is separate from register/DMA
progress; no synthetic success or generic native boot PASS can substitute for it.

## Sources

- [M5Stack Tab5 documentation](https://docs.m5stack.com/en/core/Tab5).
- [Everest ES8388 datasheet rev5.0](https://m5stack-doc.oss-cn-shenzhen.aliyuncs.com/1141/ES8388.pdf), sections 4 and 6.
- Existing pinned ESP-IDF v5.4.4 `i2s_ll.h`, `ahb_dma_ll.h` and register headers.
- Existing pinned M5Tab5-UserDemo hardware pin map; no M5Stack/MeOS audio driver
  source is imported. Original Zig/C control logic uses vendor LL definitions
  without linking an ESP-IDF audio driver, allocator or FreeRTOS.

Physical controller/DMA progress, retained pre-fix failures and the remaining
audible gate are recorded in the
[2026-10-28 checkpoint](../measurements/2026-10-28-native-audio.md).
