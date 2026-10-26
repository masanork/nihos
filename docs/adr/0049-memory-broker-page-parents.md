# 0049 Memory broker page parents and admission

Status: accepted kernel contract; host, RV32 compile, and opt-in native handoff qualified.
Date: 2026-10-27.

## Ownership and admission

One serialized broker owns metadata for internal and external page pools.
The platform exclusively transfers each registered region from its former
allocator. Internal requests never fall back to PSRAM. Regions cannot overlap
each other or the broker's metadata. The broker is initialized in place once,
remains at a stable address and rejects use of copied initialized metadata.

Owners represent an application instance or a service, not an individual task.
Opening an owner reserves its byte quotas and one group admission slot.
All group ceilings plus the free floor must fit each registered domain before
initialization succeeds. Unused reservation is not automatically lent to another
group. Fragmentation can still prevent a contiguous allocation; free bytes and
largest free extent are reported separately.

Owner identities and pin tokens include the broker instance and a nonwrapping
64-bit ticket. Lease resolution checks owner, slot, ticket, domain, canonical
pointer, requested length and charged bytes. These checks prevent accidental
stale/cross-owner use inside the kernel; raw pointers and tickets are not a
PMP boundary or a public security capability.

## Page parents and lifetime

Allocation returns page parents for service arenas/slabs/caches, not one page
per small application object. Charge `ceil(request/4096)*4096` bytes once to
the owner and group. Metadata stays outside payload and no in-band header
doubles power-of-two requests. Clear the complete charged span before returning
it, including unused tail bytes. Large clears and cleanup run in ordinary
service context, never under an IRQ mask. Small-object children remain charged
through their parent; they must not be counted again as new broker allocations.

Pin before handing a pointer to an asynchronous borrower. Each pin has its own
single-use completion token. Free refuses pinned backing. The trusted borrower
unpins only after completion/cancellation has established that the memory is no
longer in use. Pinning does not perform DMA cache maintenance, establish memory
barriers or grant hardware access; the transport adapter owns those operations.

Before `beginClose`, the caller stops every task belonging to the owner and
prevents new requests from that application/service. Closing rejects new
allocation and pin operations. `reclaimOne` releases at most one unpinned
parent per call and waits for pinned parents. Admission credit and the owner
slot remain occupied until all parents are gone. A sibling task's exit does
not authorize closing a shared application owner. Native scheduler/syscall/RPC
bindings must establish this quiescence contract separately.

## Development policy and metadata accounting

Generate `src/kernel/development_memory.zig` from the checked
[development profile](../planning/tab5-development-profile.json), recording its
SHA-256. The initial policy admits one owner per service group, at most sixteen
owners, sixty-four live parents and thirty-two active pins. It registers only
heap payload, excluding stacks, DMA, guards and boot reservations.

The 224 KiB internal heap envelope includes 16 KiB for broker metadata and its
alignment allowance, leaving 208 KiB registered payload: 48 KiB low plus
160 KiB high. Its 144 KiB of service ceilings and 64 KiB free floor exactly
cover those 208 KiB. Metadata is not also lent as kernel payload. The RV32
contract's metadata must fit its 16 KiB reservation at compile time.

The conservative external registration is 30 MiB after the profile's 2 MiB
boot/allocator/guard reservation. Service ceilings total 21.5 MiB and the
free floor remains 8.5 MiB. VM admission still reserves 8 MiB even when the
current request is 4 MiB; quota savings are a future profile change, not an
automatic cross-group loan.

The [implementation receipt](../measurements/2026-10-27-memory-broker.md)
separates this policy from the physically qualified legacy heaps. The
[opt-in native handoff receipt](../measurements/2026-10-27-broker-native-handoff.md)
qualifies exclusive post-fixture region transfer, normal task EXIT, pin completion
and slot generation reuse on Tab5. The [SD lifetime receipt](../measurements/2026-10-27-broker-sd-lifetime.md)
adds forced termination of a waiting client between CMD17 launch and software
completion, pinned SRAM-staging-to-PSRAM delivery, reply discard and clock
reacquisition/release. It does not assert that hardware was still transferring
at task stop. Boot-time replacement, multi-task owner teardown, direct PSRAM
DMA, controller abort/error recovery and C ABI integration remain separate gates.
