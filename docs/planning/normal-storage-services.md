# Normal boot storage and shared SDMMC

The normal OS must keep display/input and C6 networking running while a
read-only SD VFS request executes. Qualification fixtures remain separate:
normal boot never performs high-SRAM/PSRAM destructive sweeps, retires the
existing owner heaps, kills test clients, or requires a card/file to boot.

One CPU0 foreground host owns the SDMMC command engine and IDMAC. SD slot 0
and C6 slot 1 receive non-overlapping port register views and bounded transaction
leases. No per-slot driver can reset the controller. Slot handoff requires a
physical idle/descriptor/cache fence, including after errors. Failure retains
the owner and DMA memory and blocks both slots. Only that owner may request
whole-controller recovery; every recovery attempt advances the common device
generation so both filesystem handles and network state must be re-established.
C6-only reset/reenumeration preserves an otherwise healthy SD session.

Normal FS owns a bounded lease from the existing base SRAM pool, shared with
card-display clients. It does not install a second allocator over the same
addresses. CPU-only FS workspace and DMA staging have separate lifetime rules;
the parent remains reserved until endpoint/FS shutdown AND DMA quiescence.
The display reservation and existing PSRAM heaps retain their original owners.

Implementation sequence and acceptance:

1. A common host enforces exclusive transactions, masked per-slot clock/width
   updates, stale-lease denial, global reset epochs and quarantine. Replay both
   actual SD/SDIO drivers against shared modeled registers, including faults.
2. Native foreground adapters use this host; all standalone qualification
   profiles retain their exact exclusive paths. C6 reconnect cannot silently
   reset a mounted SD filesystem or publish an old-generation network packet.
3. A normal FS owner borrows common-pool memory and runs outside interrupts.
   No-card/unsupported/corrupt media returns a service status while UI/network
   continue. Copy-only requests retain principal/root/FD binding. Generation
   change invalidates cached FS access before another request can dispatch.
4. Native build/image/source audits cover normal display + networking + VFS;
   host tests exercise normal and failed mount/read/reconnect/teardown. Device
   evidence must separately demonstrate UI/input progress during a file read,
   SD/C6 interleaving, no-card boot and reset/removal recovery. No write/WAL or
   power-loss claim follows from these read-only paths.

Card-detect IRQ wiring and silicon in-flight abort qualification remain explicit
device gates; polling/error detection must not be reported as equivalent to an
interrupt-driven removal guarantee.

## Runtime contract

`NIHOS_NATIVE_NORMAL_STORAGE=1` builds the ordinary integer live-console
service with display/input, on-demand board devices and optional C6 networking.
`NIHOS_NATIVE_SDMMC=1` continues to select the standalone qualification path;
it is not the switch for this service. High-SRAM/broker/storage qualification,
USB/card terminal applications and finite audio/microphone/RS485 fixtures remain
separate build profiles. This separation does not claim that USB and SD are
inherently incompatible peripherals.

Normal boot creates one CPU0 service task in an existing 4 KiB worker stack.
Its 64 KiB parent comes from owner 2 in the base SRAM lease pool; display
clients use owner 1 in that same pool. No PSRAM heap is retired or probed. The
one `ui.serviceBacking` reservation still belongs to networking. Failure to
obtain FS memory leaves the shared host available to C6. The parent remains
reserved for the service's lifetime, including an unrecoverable DMA fence.

Only lease acquisition/ownership publication and private cache commands mask
interrupts. Command/transfer/fence waits keep interrupts enabled. Another
foreground task may run during a transaction, but it receives Busy for either
slot until the holder completes the physical fence. Timeout/FIFO threshold
registers are saved per slot and restored at handoff; divider, source, clock
enable and width writes preserve the other slot's fields. C6 pad initialization
must compile with `NIH_NATIVE_SHARED_SDMMC=1` to skip global reset even on a
reconnect. The common host alone calls the peripheral clock/reset shim.

A controller recovery advances the shared generation for both consumers.
Network polling retires its old addresses/output before reinitialization; FS
checks generation even for cached lookup/read/result paths. The service revokes
its live client's old root/FDs with an administrative owner operation, then
mounts a fresh epoch. It does not report a fictitious kernel task exit. Failed
I/O retires the mount; `:storage` can retry after reinsertion or an error.
Card absence never gates normal console readiness.

The serial console accepts `:storage` to refresh the mounted volume and
`:read relative/path` to read at most 4096 bytes through the authenticated,
copy-only VFS/RPC path. Requests retain the bootstrap principal and mount epoch;
only one request may remain unconsumed. Paths are bounded and copied before
submission returns. Boot mounts the volume without selecting a user file;
an empty root is valid. The screen/serial preview displays at most 128 bytes,
replacing non-ASCII/control bytes, and reports truncation. Other device commands
and normal UI Escape remain available. Directory listing, arbitrary-offset
streaming, filesystem writes and persistent SQLite are not provided here.

## Verification and limits

`tools/check-normal-fs.py` runs the actual normal task, C/FatFs, guarded backend,
VFS/RPC and SD driver with modeled MMIO/IDMAC and deterministic UI/SDIO turns.
It covers all five fixture layouts with success, no-card, reset generation,
I/O error/retry, removal/retry, corrupt mount/retry, OOM, empty root and cache
fence quarantine. Input image hashes must remain unchanged. Two isolated code
mutations must fail the same tests: permitting a stale-generation submit and
releasing the host despite a failed cache handoff. These are host observations,
not physical UI/SDIO timing or removal-IRQ evidence.

The native service has its own bounded RX text/read-only span at
`0x40020000..0x40060000`; mutable state stays in SRAM. A linked immutable identity
binds the source/upstream/object manifest and function allowlist to the image.
`tools/check-normal-native.py` rejects five edited or absent sidecar claims
against the real ELF. This is a candidate identity check, not attestation.
The image audit enforces per-frame worker margins and forbids write/heap APIs.
Structural call-chain analysis still retains ROM-cache, syscall and callback
boundaries; passing a frame bound does not close the whole-stack gate.
