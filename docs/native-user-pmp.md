# CPU0 protected native-task fixture

PR #76 adds a kernel-controlled CPU0 task class with an RX code grant and a
private RW, non-executable arena. Kernel workers remain in M-mode. Admission
defaults to denied; only the explicit headless diagnostic fixture opts in.
The normal display, card, network and SQLite applications are not migrated.

The port loader denies the CPU-subsystem, CPU-peripheral and mask-ROM windows
using unlocked entries 0–2. The runtime rejects a stale or incompatible loader
contract before registration. Entries 4–7 encode the two 128-byte-aligned TOR
grants. Installing a grant removes the loader's broad SRAM/Flash/LP grants;
selecting a kernel task removes the user grant. M-mode bypasses unlocked PMP.

ESP32-P4 v1.3 reports load/store bus errors asynchronously by default. With
that mode, the CLIC access at `0x20800000` stalled this fixture. CPU1 observed
the user marker immediately before the load, but no new trap-entry marker.
A subsequent JTAG halt read a load/bus-error state in M-mode; this snapshot
alone does not prove the precise microarchitectural stall mechanism.

Setting `mhint.SBE` (bit 20) made the same CLIC load fault at the user `lw`.
The final writer sets SBE while installing a user grant and clears it when
dropping that grant, preserving the other `mhint` bits. Normal kernel-only
execution never enters this writer. The physical fixture checks SBE readback
both while handling the protected task and after returning to the kernel.
See the [v1.3 TRM, section 1.13.1.2](https://documentation.espressif.com/esp32-p4-chip-revision-v1.3_technical_reference_manual_en.pdf).

Fault cleanup exits only the protected task with `-70`, closes its resource
ledger, drains it, and reaps the slot before reuse. ECALL accepts scalar values,
not task pointers. The return path writes `mcause` before `mstatus` and keeps
MIE clear until `mret`. Tasks whose saved privilege disagrees with their
protection metadata are refused.

Build the complete bounded fixture with:

```sh
NIHOS_NATIVE_DISPLAY=0 NIHOS_NATIVE_CONSOLE=0 \
NIHOS_NATIVE_CONSOLE_LIVE=0 NIHOS_NATIVE_PSRAM_200=0 \
NIHOS_NATIVE_PMP_PROBE=1 NIHOS_NATIVE_PMP_CASE=all \
sh tools/build-native.sh device
```

This builds an image; it does not flash it. `NIHOS_NATIVE_PMP_CASE=0..11`
selects one case. Physical flashing requires exclusive device ownership, a
full original-image backup, candidate verification immediately before capture,
and full-image restoration verification afterward.

| Case | Required result |
| --- | --- |
| 0 | Allowed ECALL, timer interrupt taken from U-mode, return and exit 1 |
| 1 | Address-zero load fault |
| 2 | Store to RX code fault |
| 3 | Instruction fetch from RW arena fault |
| 4 | Invalid user SP rejected on ECALL |
| 5 | Privileged CSR instruction fault |
| 6 | HP peripheral `0x50000000` load fault |
| 7 | CPU cache register `0x3ff10000` load fault |
| 8 | CLIC `0x20800000` load fault |
| 9 | Valid kernel SRAM `0x4ff00000` load fault |
| 10 | Mask ROM `0x4fc00000` load fault |
| 11 | Instruction-fetch fault exactly at mask ROM `0x4fc00000` |

Every case also checks kernel privilege, grant removal, reap and generation
reuse. A fault later inside ROM is not a successful case 11. The firmware
reports the maximum observed PMP-arm and C-dispatch cycles with MIE clear.
These include measurement overhead and observed Flash/cache effects; they
exclude the assembly trap prologue/epilogue and are not worst-case latency
bounds. SBE increases user load/store latency; it is not enabled globally.

Raw logs, image hashes, source identity, repeated warm-reset results and
restoration receipts are in
[the physical evidence directory](measurements/2026-10-30-pmp-synchronous-faults/receipt.json).
ESP-EMU v0.50.0 does not model SBE readback. Its matrix is labelled
`sbe_evidence=unmodeled` and does not qualify physical bus-error behavior.

This evidence covers the CPU0 fixture on the identified Tab5 ESP32-P4 v1.3.
It does not qualify other silicon revisions, cold power cycles, long-duration
operation, DMA/APM isolation, hostile peripherals, arbitrary native applications
or a production untrusted-code loader. PMP is per hart and does not constrain
DMA. The original 16 MiB firmware is restored after each physical session.
