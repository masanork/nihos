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
