# Multi-client VFS: RV32 layout and existing normal-FS budget

`python3 tools/check-vfs-multi-budget.py` builds target-layout probes for the
host multi-client prototype and an instrumented copy of the existing normal-FS
module with sqld enabled. The latter exports only `@sizeOf(State)` and
`@alignOf(State)`; it does not wire the prototype into normal FS. The command
also compiles and runs a synthetic address-only test of the actual SRAM pool.
Selected source hashes, target values and the exact source checkout head appear
in its JSON output. This is compile-only sizing, not a native linked candidate.

On the checked revision, RV32 reports:

| Item | Bytes |
| --- | ---: |
| Request copy | 4,672 |
| Response copy | 4,136 |
| One endpoint's two rings | 18,176 |
| Service owner, including its own frames and VFS | 12,984 |
| Two endpoint rings, owner and issuer, including alignment | 49,408 |
| Existing normal FS `State` | 63,744 |
| Existing normal FS parent | 65,536 |

The existing parent has 1,792 bytes unused by `State`. Simply adding the entire
prototype to the existing state, aligned to 128 bytes, requires 113,152 bytes:
47,616 bytes over that parent. This additive calculation deliberately retains
the existing VFS and queues; a replacement design could share or remove some
of them, but has not been designed or measured. Client frames and stacks,
new backend workspace, allocator fragmentation and other owners are excluded.
The development-profile 512 KiB PSRAM VFS envelope is a target, not a live
reservation, and cannot establish admission or a safe DMA/IRQ lifetime.

The same compile reports 128-byte alignment for both the current normal-FS
`State` and the combined prototype. The base SRAM pool contract guarantees
only 64-byte alignment. The synthetic allocator test demonstrates a legal
fragmented pool arrangement that returns a 64-aligned, non-128-aligned 64 KiB
lease. This exposes a contract mismatch; it does not establish that the current
normal workload actually reaches that arrangement. A native design must ensure
and test alignment, allocation, lifetime, device fences and competing-owner
admission before enabling the prototype. No physical, runtime heap-availability,
cache-off, stack-usage or SD write result follows from this probe.
