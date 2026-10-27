# ADR 0048: Incremental native BMI270 acquisition

- Date: 2026-10-27
- Status: implemented; physical results in the measurement checkpoint
- Extends: [ADR 0047](0047-default-connectivity-and-board-devices.md)

## Behavior

Normal native Tab5 boot now initializes BMI270 and acquires accelerometer and
gyroscope readings. Previously it only read chip identity and initialization
status. The existing CPU0 board I2C owner services initialization and sampling
between its RTC/INA226 jobs. CPU1 and IRQ handlers do not access this bus.
No shared-bus reset or recovery is added.

The independent Zig driver soft-resets the identified BMI270, disables advanced
power save, transfers the pinned base configuration in 32-byte chunks, and
checks INTERNAL_STATUS. INIT_ADDR uses word addresses, not byte addresses.
INIT_CTRL completion is issued once per sensor reset, including warm P4 boots.
Each poll executes at most one I2C transfer. Mandatory delays begin after that
transfer completes, using a free-running microsecond timer; there are no
blocking initialization sleeps. RTC and INA226 retain their separate jobs.

Bosch's unmodified 8192-byte configuration is BSD-3-Clause licensed and mapped
in the existing non-executable Flash table page. Its source commit, digest,
extraction and original notice are retained under
[`src/board/tab5/bmi270`](../../src/board/tab5/bmi270/README.md) and
`provenance.toml`. Native image outputs include `licenses/BMI270.txt` for binary
redistribution. No Bosch host driver is imported.

## Measurement contract

ACC_CONF=0xa8 and GYR_CONF=0xa8 select normal filters and nominal 100 Hz sensor
output. ACC_RANGE=1 selects +/-4 g (8192 counts/g); GYR_RANGE=2 selects +/-500
degrees/s (nominal 65.536 counts per degree/s). Configuration and power settings
are read back before readings are accepted. Polling, I2C and the other services
determine the lower host acquisition rate; this is not a lossless 100 Hz stream.

Both data-ready flags must be asserted before the coherent 12-byte sensor
burst is read. Each accepted burst increments the sample counter. A sensor
error, transport/clock failure or one second without fresh data retires validity
and stops acquisition; old readings are never published as valid after a fault.
There is no automatic retry/reset loop on the shared bus. Restart requires an
explicit owner restart. Failures remain local to the IMU and do not stop boot.

`NIHOS_NATIVE_IMU` reports initialization/upload progress, faults, sample count,
and six signed raw axes represented as sign-extended 32-bit hex. These are chip
axes, without display/board remapping, bias calibration, orientation estimation,
FIFO, interrupts, step detection or application IPC. Register identity alone
does not qualify acquisition. The checker requires continued fresh readings,
complete upload, no faults and repeated gravity-sized acceleration. Controlled
movement, gyro calibration and optical confirmation remain separate evidence.

## Validation

Host models compare every uploaded byte with the pinned configuration and
verify its SHA-256, word addressing, one-transfer budget, delayed completion,
signed-axis decoding, readback failure, incomplete initialization, data-ready
gating, timeout, sensor faults and transport failure. RV32 code generation of
all driver states is part of the architecture gate. Existing six image profiles
and the normal connected image retain the unchanged 48 KiB primary heap floor.

See [the physical checkpoint](../measurements/2026-10-27-native-imu.md) for the
exact candidate and remaining qualification boundaries.
