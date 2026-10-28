# ADR 0054: Normal single-contact touch input

- Date: 2026-10-28
- Status: implemented locally; normal-image physical qualification pending
- Extends: [ADR 0052](0052-default-on-demand-device-drivers.md)

## Decision

The normal DEVICES profile includes the existing panel-matched touch driver.
It exposes a bounded CPU0 pointer stream and a visible upper-right LOGS/SPLASH
control in the live diagnostic UI. This is the first normal input consumer;
it does not expose card, PIN, USB or network operations through touch.
DEVICES=0 and existing standalone fixture profiles omit this service.

The adapter borrows the board service's foreground I2C master and running
microsecond timer. It does not repeat the standalone touch fixture's timer,
power or bus initialization, and never runs an I2C transaction from an IRQ or
another hart. Identification is deferred until one second on the existing
clock, then polling is limited to approximately 30 Hz. There are no new DMA
buffers or dynamic allocations. The existing driver's ten-slot bound remains;
the maximum foreground identification/sample duration is reported for physical
measurement rather than inferred from the poll frequency.

Display panel IDs select GT911 (ILI9881C), ST7123 or ST7121. The portrait
720x1280 controller coordinates map to the existing landscape raster as
`x = 1279 - raw_y, y = raw_x`. The control occupies logical x=1120..1263,
y=16..79 and is painted after the splash or console raster, including partial
header updates. It appears only after controller identification and UI input
activation. Serial input remains available if touch fails.

## Input contract

`src/input/pointer.zig` defines down, move, up and cancel events with monotonic
timestamps and sequence numbers. The eight-event queue and native pop API are
CPU0 foreground contracts, not cross-core IPC. Only fresh single-contact
reports begin or move a stream. Only a fresh zero-contact report releases it;
absence of a report never becomes an up event. Multiple contacts, malformed
coordinates, hardware failure, queue overflow or a stale held stream cancel
the gesture. Cancellation blocks new down events until explicit release.
An I2C/identification failure disables the adapter until reboot without
resetting the shared bus or other board devices.

The view control requires down and up inside its bounds, at most 24 pixels of
movement per axis, and at most 1.5 seconds of holding. Dragging out and back,
long holds, cancelled streams and release without press do not activate it.
Its action uses the existing diagnostic model; key reports identify source=5
(touch). The capability mask adds bit 16 after identification, so serial+touch
is 17. Pre-activation queued events are discarded. Fatal UI state hides the
control and rejects touch actions.

## Observability and cost

`NIHOS_NATIVE_TOUCH_UI` reports availability, input capability mask and logical
control bounds. Five-second `NIHOS_NATIVE_TOUCH_INPUT` records report status
(0 pending, 1 ready, 2 failed), display panel ID, geometry, slot count, poll and
fresh-report counters, errors, error code and maximum poll microseconds.
Error codes are timer=1, unknown panel=2, identification=3 and sample=4.
`NIHOS_NATIVE_POINTER` reports down/move/up/cancel/multiple-contact/overflow
counters, a four-quadrant bitmask and queued event count. It does not log raw
touch coordinates. The existing DEVICE_SERVICE bitmap still describes the
three requestable audio/microphone/UART drivers.

The configured connected candidate leaves 58944 bytes of primary static heap,
versus 63424 bytes before this change: 4480 additional static SRAM bytes. Its
approved Flash records occupy 56603 bytes. The 49152-byte minimum static heap,
SRAM banks, stacks and image-auditor rules remain unchanged. These are link
layout results, not physical free-heap, timing or power measurements.

## Validation and physical gate

Host Debug and ReleaseSafe each pass 407 tests, including rotation, explicit
release, stale/multiple-contact cancellation, overflow quarantine and rejected
button gestures. Raster tests check rotated bounds, stride padding and rejected
input without frame mutation. Static analysis and RV32 links pass. The
configured connected device image builds and passes its loader/image audit.
The unconfigured-Wi-Fi normal profile also links, and the Python suite passes
238 tests.
Host previews of both views show the control without obscuring their headings;
they are not optical device evidence.

At this checkpoint USB serial is absent, so this candidate has not been
installed or physically qualified. Earlier standalone ST7121/card observations
do not establish operation of this normal image. Before landing:

1. Rediscover the device and coordinate exclusive write ownership. Back up the
   actual app and verify retained loader identity before installing. Verify the
   exact candidate bytes before and after capture; restore and verify the prior
   app afterward.
2. Observe ready controller geometry and continuing display/hart, Wi-Fi,
   RTC/IMU and finite-device operation. Measure maximum foreground touch work;
   do not derive responsiveness from the 30 Hz poll target alone.
3. Confirm visibly that tapping LOGS and then SPLASH changes the respective
   views. Require source=5 accepted actions and fresh down/up counters. Exercise
   all four quadrants, outside taps, holds and multiple fingers; they must not
   produce an unintended view action. A controller that supplies no explicit
   release must remain unable to click until its protocol is established.
4. Retain failed attempts and optical/input confirmation separately from serial
   counters. GT911/ST7123, cold power cycling, IRQ input, application routing
   and sustained mixed workload remain separate qualification work.
