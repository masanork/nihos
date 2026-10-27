# C6 networking integration rebase checkpoint

2026-10-27. The networking branch was rebased onto a local integration base
containing both the display/console normal-boot branch and remote main.
The rebased network fixture was rebuilt and physically requalified.

## Source integration

| Input | Commit |
| --- | --- |
| Display/console normal boot (`codex/native-console`) | `8cd0076` |
| Remote main snapshot | `b7658d6` |
| Local merge base (`codex/c6-integration-base`) | `98a122e5ec190c3d37449aeae475328695c30ea5` |
| Pre-rebase networking evidence | `24e28f2` (`evidence/c6-ipv6-pre-integration`) |
| Replayed networking HEAD before integration fixes | `b9ddf7e` |

These are local branch operations; no remote branch was force-pushed. Other
worktrees, including the dirty main worktree, were left untouched. Both SQLite
and ESP-AT provenance records and both allocator/formal and C6 checks survive.
C6 ADRs moved to 0043/0044 to avoid the normal-boot branch's ADR numbers.

Normal boot now has a different memory contract from the CPU0 network fixture.
The fixture keeps its pre-rebase 128 KiB linker and SRAM/ROM boundary audit in
`probes/c6-sdio/esp32p4.ld` and `tools/check-c6-sram-boundary.py`. This avoids
relaxing the newer normal-boot image audit or pretending the fixture uses the
normal OS stack layout. Both audit test suites run. The normal-boot linker,
image auditor and auditor tests match the integration base unchanged.

Two existing lint findings in the integrated base were corrected: express the
PSRAM index's existing 8-bit truncation as a mask, and group consecutive shell
redirects when generating native options. Their intended behavior is unchanged.

## Verification after rebase

- Debug host suite: 275/275 passed; ReleaseSafe host suite passed.
- Format, ZLint and shellcheck passed.
- Normal image audit tests: 21/21; fixture audit tests: 5/5.
- RV32 architecture probes and six native ELF links/audits passed.
- Native integer emulator fixture: 300 rounds, lifecycle, IPI/idle and owned
  memory checks passed. This does not qualify a physical display.
- Normal-boot headless emulator suite: all 8 cases passed, including four
  PSRAM sizes, console-ready/idle paths and three expected failure cases.
  Its report explicitly excludes physical display and PSRAM-200 qualification.
- Private Hosted IPv6 image rebuilt and audited; all 21 receipt input hashes
  and all artifact hashes match the retained build.

## Rebased physical candidate

The board was rediscovered as P4 rev1.3 on `/dev/cu.usbmodem101`; its factory
application at `0x10000` was replaced and the write verified. Bootloader,
partition table, C6 firmware and SD were not written. No full-flash backup was
made, as explicitly requested by the user.

| Observation | Result |
| --- | --- |
| Factory C6 firmware | ESP-Hosted 1.4.1 |
| IPv4 DHCP | `10.193.127.151/24`, gateway `10.193.127.155` |
| Preferred IPv6 link-local after DAD | `fe80::9aa3:16ff:feb6:a4ec` |
| Mac Echo test, started after link-ready marker | 5 sent / 5 replies, 0% loss |
| RTT min/avg/max | 18.040 / 65.048 / 234.806 ms |
| Router solicitation / advertisement | 3 / 0 |
| Incoming NS / Echo requests | 1 / 5 |
| IPv6 malformed drops | 0 |
| Final marker | `NIHOS_C6_IPV6_PARTIAL` |

The 67,760-byte candidate reserves 101,376 bytes of SRAM and leaves an unused
29,696-byte heap span. It has no P4 RTOS or FP instructions. Exact hashes:

- bin: `ffbb1854aa6c923f8b4fce094a04af6345696a9eb184ce18a782d178a59bc47f`
- ELF: `6f7b64023f258c57f9cbaffde0ee0a7bf6dec19f9b8e11649123c9b887416ab3`
- `run-05.log`: `1aabc7df3424498e466cf4d6dd5e907bd05acaf9be9e075546386969166aecaa`
- `mac-ping6-05.log`: `490fe8b309302b263e26f0b515d82cba10cc56064ac50eea38ac97ed3d09490d`

Private evidence is under `build/wifi-device/physical-02/`, including
`ipv6-rebased-result.json`. The receipt records `b9ddf7e` plus uncommitted
integration changes and exact input hashes. Earlier evidence and candidate
artifacts remain separately retained; their hashes differ from this candidate.

The AP did not advertise an IPv6 prefix, so physical SLAAC, outgoing router
Echo and global reachability remain unqualified. Display and networking are
integrated in the source history, but have not run together on hardware.
The current board application is still the headless network fixture, which
halts after its report. The [IPv6 limits](2026-10-27-native-ipv6.md#limits)
continue to apply.
