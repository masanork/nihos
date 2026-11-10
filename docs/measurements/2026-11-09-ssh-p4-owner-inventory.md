# P4 SSH entropy ownership inventory

This is a source inventory, not a hardware ownership receipt or an entropy
qualification. Native SSH remains unavailable.

* The foreground tick is read from a Timer Group channel and passed into the
  entropy clock guard. The `TickTimer` adapter avoids asking that guard to
  capture the foreground timer again. The UI/native timer group and the LP
  timer are different register blocks.
* The sampler nevertheless calls `Hardware.lowTimerByte`, which writes the LP
  timer snapshot bit at `0x50112010` and reads `0x50112014` for each mixing
  step. That write shifts shared snapshot buffers. Exclusive LP snapshot
  ownership remains necessary. The host fake records both the guard counter
  reads and these LP snapshot writes separately; it verifies snapshots occur
  only while its simulated resource reservation is held. This is not a proof
  of exclusion from native, ROM, firmware, interrupt, or other-core users.
* `cpu_clock.zig`, `psram_mpll.zig` and `sar_regi2c.zig` use the analog-I2C
  controller at `0x50124000`. Native boot invokes the CPU clock and PSRAM paths
  before the foreground can run. Their source-level boot ordering is not an
  exclusive runtime lease and does not establish that all other clients have
  stopped or can never use the shared selectors.
* The SQLite RNG gate serializes SQLite and SSH use of the RNG, but it does
  not own both SAR ADCs, analog-I2C, the LP timer, or clock/power controls.
  `p4_entropy_lease.zig` requires a separate owner covering those resources
  through ADC and analog restoration; that native owner is not implemented.

Before enabling a native source, identify and coordinate every relevant client,
including opaque ROM/firmware and interrupts, establish stable timer and power
ownership, and qualify physical entropy, cleanup, cache-off behavior and the
live network on the exact device image. A source search or a host fake cannot
establish those properties.
