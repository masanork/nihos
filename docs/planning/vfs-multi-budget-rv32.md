# Multi-client VFS: RV32 layout and existing normal-FS budget

`python3 tools/check-vfs-multi-budget.py` builds target-layout probes for the
host multi-client prototype and an instrumented copy of the existing normal-FS
module with sqld enabled. The latter exports only `@sizeOf(State)` and
`@alignOf(State)`; it does not wire the prototype into normal FS. The command
also compiles and runs a synthetic address-only test of the actual SRAM pool.
Selected source hashes, target values and the exact source checkout head appear
in its JSON output. This is compile-only sizing, not a native linked candidate.

For the earlier 4 KiB-frame baseline, RV32 reported:

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

## 512-byte frame experiment

The current host prototype uses 512-byte read and write frames with queue depth
2 per endpoint. On RV32 the two endpoint queues, service owner and issuer now
measure 13,568 bytes, versus 49,408 bytes for the preceding 4 KiB-frame
prototype. Adding this entire object to the unchanged 63,744-byte normal FS
state still needs 77,312 bytes, above the 65,536-byte parent. Replacing existing
owner and queues requires a separate design; the type projection below does not
establish that replacement works.

The host fixture manually splits 4 KiB transfers into eight 512-byte requests
per client and checks interleaving. It does not implement an automatic transfer
coordinator, atomic multi-chunk writes or safe retries. A test deliberately
returns timeout after writing a chunk and confirms that the outcome is unknown
and another queued client is blocked. Stack use, real-device throughput, DMA,
physical power failure and writable production FatFs remain unqualified.

## Replacement type projection

The probe also constructs an RV32 type from the actual normal FS `State`,
replacing its owner, queues, client frames and notifications with the host
service, two endpoint queues and one request/response frame. All other fields,
including the 32 KiB C workspace, command ring, result and DMA fields, remain.
This projected type is 55,424 bytes with 128-byte alignment, leaving 10,112 bytes
in the existing 65,536-byte parent. The request and response together account
for 1,640 bytes. The 8-byte issuer must live outside a reconstructed service;
additional client frames and stacks are not included in the parent figure.

This is a type-layout experiment, not a working runtime replacement. The
service's host contracts do not yet replace native notifications, cancellation,
producer lifetimes, client authentication, or device fences. Integration can
change the final layout and may require additional storage. The separately
proposed aligned allocator must be present; the older 64-byte pool contract
cannot guarantee this type's 128-byte alignment. The host service now supports
a read-only mount so the existing normal FS policy can be preserved during
future integration. No physical-device behavior is established here.

The later chunked-reader host model adds a 56-byte RV32 state object. Including
it in the same projected State results in 55,552 bytes and 9,984 bytes of parent
headroom. It reuses the one projected request/response frame and existing 4 KiB
result buffer; it adds neither another buffer nor the persistent issuer. Actual
integration may change the layout, and stacks, the other client's frames,
notifications and device fences remain excluded.
