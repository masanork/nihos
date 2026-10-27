# Native DHCP renewal and controlled C6-reset recovery

2026-10-27. After the configured AP became available, the unchanged networking
sources at `ed70501` acquired IPv4, received a real early-renewal DHCP ACK,
revoked addresses during the diagnostic C6 reset and acquired them again.
The P4 normal-boot UI and both schedulers continued throughout the test.
This extends the earlier [AP-absence checkpoint](2026-10-27-network-lease-lifecycle.md).

## Candidate identity and procedure

P4 rev1.3 on `/dev/cu.usbmodem101`, existing factory C6 Hosted firmware.
The retained candidates' 250 source-snapshot hashes match the worktree and
committed implementation. No networking source changed for these tests.
Application writes were verified at `0x10000`; bootloader, partition table,
C6 firmware and SD were not flashed. No full-flash backup was made, per the
user's instruction.

A serial attachment to the already installed normal image produced a new
warm boot and acquired `10.193.127.151`; it is not evidence of uninterrupted
AP reappearance without a P4 reset. The exact retained diagnostic image was
then written, captured for 200 seconds, and checked with the unchanged
normal-boot/core/memory/display validator.

`network_test=true` requests one early DHCP renewal ten seconds after initial
acquisition completes, retaining the actual server lease duration. Forty
seconds after completion it resets C6 once. The P4 image does not restart.
Normal images have both diagnostic injections compiled out.

## Diagnostic physical result

| Observation | Result |
| --- | --- |
| Initial acquired IPv4 | `10.193.127.151` |
| IPv6 link-local DAD state | Preferred before and after recovery |
| Matched renewal ACK | One, before the diagnostic reset |
| Address retirement | Disconnect message and zero IPv4/link-local state before re-acquisition |
| Acquisitions / reconnects | 2 / 1 |
| Recorded failures | 1, during the diagnostic reset sequence |
| Re-acquired IPv4 | `10.193.127.151` |
| P4 application boots in capture | 1 |
| Display frames | 32 → 11,732 |
| Both scheduler timer counters | 15 → 19,522 |
| Accepted serial display controls | 3, at 30/70/100 seconds |
| Maximum observed networking poll | 6,973 us; not a worst-case or IRQ bound |
| Final state | Active, acquisition complete, addresses present, no current error |

The renewal counter increments only after a DHCP ACK with the current
transaction ID, selected server and valid lease fields is accepted while
renewing/rebinding. Address-cleared and re-acquired states and monotonically
increasing UI/timer counters were retained in the log. The brief one-second
backoff can fall between five-second reports; no claim is made that its
error-code sample was captured. The diagnostic source and compiled build
option establish the controlled-reset procedure.

Exact diagnostic image:

- Bin: `de65456be4d0673f450b5ce05a680c348288f407053d9589e30d7036dc0986d3`
- ELF: `f1698cd1ea6420c3612653e48f77c7cf232a5f53126a93b17d5ae8c31afe356b`
- Serial log: `015b21f9693297207d1ca47e98af64ba404042afc767f9d8d1e0fec24909f515`
- Application / SRAM heap: 154,800 / 53,248 bytes.

Private evidence: `build/wifi-device/renewal-02/`, including
`diagnostic-result-01.json`, `display-result-01.json`, raw serial/write logs
and the validation script. Immutable candidate snapshots and receipts remain
under `build/wifi-device/renewal-01/`.

## Scope and remaining gates

The Mac remained on a different IPv4 network, so no Mac-to-Tab5 Echo test was
performed in this run. Preferred link-local state is distinct from a new
peer-traffic qualification. Earlier Echo measurements remain scoped to their
own candidates. Physical keyboard presses and optical display quality were
not tested; the accepted controls here came from serial.

The positive renewal is an explicitly early request. Natural T1/T2 timing,
rebinding after server loss, expiry/NAK against a real server, AP disappearance
and reappearance during one uninterrupted P4 session, long-duration traffic,
cold power cycles and global IPv6 remain open. Host timer/error regressions
from the implementation checkpoint are unchanged; no new source required a
host-suite rerun. MicroSD arbitration and application sockets remain separate
implementation stages.

## Normal image restored and checked

The exact normal image was restored after the diagnostic run and captured for
135 seconds. It acquired `10.193.127.151`, kept preferred link-local state,
and remained active beyond the former 120-second boundary with one acquisition,
zero failures and zero reconnects. No early-renewal/reset injection ran.
Display frames increased 32 → 7,832 and both scheduler counters 15 → 13,020;
three serial display controls were accepted. The unchanged normal-boot/display
checker passed again. Maximum observed networking poll was 6,970 us.

- Bin: `6ace7cc67f3173095a3301b066cde37315c55233891f9504f2e89fc241e6d354`
- ELF: `23aff517c3705b4dacf05003e9904215f8123ac3f9a56174abd41e0a98750ed1`
- Serial log: `7df9e1047ac53507e95ab556260a2495727787bbb78dbc616b69c601b6178f43`
- Application / SRAM heap: 154,416 / 53,632 bytes.

The source/artifact receipt matches all 250 input hashes. Private
`normal-result-02.json` and `display-result-02.json` retain the checks. The
board is left on this normal image with its acquired address and retry/lease
maintenance enabled. This short normal run did not reach natural T1.
