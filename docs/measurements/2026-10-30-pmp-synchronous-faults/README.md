# Tab5 v1.3 synchronous protected faults

Runtime source: `d39c1b99fb034fdb7580e61580ddf18329c68f03`.
The enclosing evidence-only commit does not change runtime sources.
`receipt.json` binds the source files, ELF, actual flashed images and raw logs.
The loader binary is the same verified binary used in the preceding ROM test;
its source contract is unchanged. No further PMP placement was tried.

All 12 cases passed on three separately verified warm starts. Every run reuses
slot 1 through generations 1–12; only protected tasks exit on faults. Case 0
includes a timer interrupt actually taken from U-mode. Every case records
`mstatus=00001880`, user SBE set and kernel SBE clear. Case 8 faults on the
CLIC `lw`; case 11 faults exactly at the ROM entry address.

At 360 MHz the largest observed PMP-arm sample was 5,146 cycles (14.29 us);
the largest C-dispatch sample was 22,224 cycles (61.73 us). Samples include
counter-read overhead and encountered cache effects. They are not a cold-cache
survey or a worst-case latency bound, and exclude assembly trap entry/exit.
The mode switch and timing counters are absent from the ordinary M-only path.

`controls/observer.patch` applies to `86a99d0` in an isolated diagnostic tree.
It adds CPU1 observation and the user-arena marker; it is not product code.
The asynchronous control reaches marker `c1080001`, never records a new trap
marker and leaves CPU1 running. Its JTAG snapshot is after debugger intervention
and must not be mistaken for an untouched lockup-state sample.
`controls/synchronous-mode.patch` changes only `mhint.SBE` in that diagnostic
tree. The same case 8 then faults and returns to the kernel. This establishes
an effective fix for the observed fixture; the precise internal stall mechanism
is not established by these traces.

The capture scripts are the archived session harnesses with their original
absolute input/output paths, selected device identity and shared write lease.
They are audit artifacts, not a portable flashing interface. They back up all
16 MiB, verify candidates before capture, and restore/verify the whole original
image in `finally`. Full Flash backups and firmware binaries are not committed.
The restored SHA-256 is
`d9411b6af948100f86e61b88fd8b6ab9e92f50f5ddbfddc78eecd34500c08f10`.

The emulator passes the 12-case control-flow matrix but does not implement
SBE readback. Its log explicitly says `sbe_evidence=unmodeled`. Only the physical
runs establish the synchronous-mode behavior. Cold power cycles, other chip
revisions, DMA/APM and arbitrary application loading remain outside this result.
