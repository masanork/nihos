# ADR 0050: Finite native microphone input

- Date: 2026-10-28 JST
- Status: opt-in qualification fixture, not application recording support
- Based on main `64c67d6`, after PR #10 finite speaker output

`NIHOS_NATIVE_MICROPHONE=1 sh tools/build-native.sh device` selects one finite
ES7210 input request ten seconds after normal device boot. Normal builds keep
it disabled. The fixture and speaker-output fixture cannot run together: both
own I2S0, MCLK30/BCLK27/LRCK29 and the AHB-DMA controller's common memory ranges.
GPIO28 is microphone data input; GPIO26 speaker data output is not configured.
ES8388 DAC/amp shutdown is checked before ADC configuration. Shared board I2C
still belongs to CPU0; no bus or expander reset is introduced.

The ES7210 identity must be 0x7210 before any configuration write. ADC mute,
reserved-bit-preserving readback, analog input selection, 24 dB analog gain,
0 dB digital gain, ALC disabled and four-slot 16-bit TDM are explicit. Nominal
MCLK is 4.096 MHz from XTAL40M / (9+49/64), BCLK is MCLK/4, and 64 bits/frame
give nominal 16 kHz. These calculations do not qualify actual analog frequency.
TDM slots are reported as raw slots 0..3; ES7210 TDM I2S order is ADC1/3/2/4,
which does not alone identify the board's microphone and reference wiring.

I2S runs for a 250 ms analog settling period without DMA. Settling FIFO data
is discarded. The finite request then resets the receiver/FIFO and starts
AHB-DMA RX0 with one terminal descriptor and 1024 bytes of internal SRAM.
This is 128 frames / 512 samples / nominal 8 ms, not a continuous recorder.
RX stop-on-successful-EOF bounds the peripheral at the programmed receive
length. Descriptor size/length/EOF/address and ownership are checked only after
DMA is parked, disconnected, RX stopped via a bounded update and its clock
disabled. There is no RX-idle status bit on this silicon; the code does not
invent one. DMA park and descriptor ownership qualify memory quiescence.

ADC shutdown attempts mute, bias/ADC power-down and internal clock-off even
when one operation fails. DLL power-down requires confirmed internal clock-off.
DMA stop is attempted independently of I2C shutdown. Stop/cache/ownership
failure retains static storage and prohibits analysis, erasure or restart.
Only proven returned storage can be analyzed. Raw signed PCM stays local;
only per-slot peak/span, active-slot mask and clipping count are logged. The
buffer is zeroed and cache-writeback checked before an erasure receipt. No
raw audio file or network upload is produced.

`NIHOS_NATIVE_MICROPHONE_MUTED=1` keeps both ADC pairs muted for a separate
negative-control image. Its finite DMA completion must still succeed but all
PCM statistics must be zero. The unmuted image must show at least two varying
slots with bounded clipping. Source/image/log identities remain distinct; a
muted image cannot substitute for input evidence or vice versa.

Host checks cover finite memory bounds, RX ownership/length/EOF validation,
signed extrema, interleaved slot statistics, settling, timeout, wrong EOF,
DMA faults and independent shutdown failures. The evidence checker rejects
mixed boots, faults, incomplete cleanup/erasure, bad statistics and wrong mode.
The native C alias is checked against the SDK; compiling the reproduced wrong
DW_GDMA base must fail the intended static assertion.

Streaming/refill, application IPC, AEC, physical mic/reference slot mapping,
known acoustic stimulus, calibrated levels, prolonged recording, cold power-on
and active Wi-Fi AP traffic remain outside this fixture's qualification.

References: [Tab5 wiring](https://docs.m5stack.com/en/core/Tab5),
[Everest ES7210 rev2.0](https://uploadcdn.oneyac.com/attachments/userfile/68/63/1629167664244_5904.pdf)
sections 4 and 7, and the repository's pinned ESP-IDF v5.4.4 LL/register headers.
The vendor PDF is reference-only and is not redistributed.

Exact physical input/muted-control results and retained preflight rejections
are in the [microphone checkpoint](../measurements/2026-10-28-native-microphone.md).
