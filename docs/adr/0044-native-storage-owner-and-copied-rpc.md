# ADR 0044: Native storage owner and copied RPC

- Status: accepted for opt-in two-task qualification
- Date: 2026-10-26

## Decision

After the ordinary native SMP and IPI tests retire their workers, one native
task on CPU0 owns the retained SD controller and read-only file backend. One
native client task on CPU1 uses separate fixed-capacity request and reply
queues. This placement qualifies cross-core operation; the generic protocol
does not identify a service with a CPU. Dynamic placement is not implemented.

Requests copy sequence, operation, handle, offset, length and a bounded path.
Replies copy status, metadata and at most 512 data bytes. There are no raw
client pointers or caller-selected owner IDs in messages. Each endpoint binds
the kernel-created task handle/generation and the corresponding runtime C
identity. A sequence is accepted once and never wraps back to a live value.
The owner reserves reply credit before consuming a request. Queue state is
authoritative; producers publish before setting a latched notification flag
and raising the target IPI.

Two SPSC queues and client scratch values occupy an 8 KiB reserved PSRAM
window at `0x48004000`, disjoint from the FS workspace, mapping samples,
peer handoff words and general heaps. Message scratch lives there to avoid
multiple large struct temporaries on 4 KiB task stacks. Both workspaces are
cleared only after their users have stopped. SD DMA continues to use internal
SRAM staging; it never targets these PSRAM buffers directly.

Only resident atomic flags are accessed by the new IRQ hooks. The trap tail
handles notifications and records a matching client EXIT tombstone; it does
not enter littlefs or access queue payloads/FS state in PSRAM. The owner task
observes the tombstone and releases the client-owned file. Kernel reaping is
gated on deferred allocation cleanup and the storage cleanup acknowledgement,
so a retired client stack is not reused before file cleanup completes.

The first fixture deliberately exits with an open file after receiving all
outstanding replies. It tests normal EXIT cleanup. Forced death during an
in-flight operation, dropping pending requests/replies after client death,
multiple clients and restarting the service are separate gates.

## Timebase and placement

TG0.T0/T1 remain owned by the two schedulers. TG1.T0 is configured before CPU1
release as an alarm/interrupt-free 1 MHz counter (40 MHz XTAL / 40), including
readback and group watchdog handling. Runtime SD polling uses only this
counter and does not stop or reconfigure scheduler timers. No SD controller
reset or power cycle occurs when handing the healthy boot controller to the
owner task. The complete SD host is still exclusively owned; C6 Wi-Fi/slot 1
arbitration and hot removal/recovery are not implemented.

The service is a separate Zig object. Its text and constants share the audited
SQLite Flash mapping, while its mutable atomics and IRQ hooks remain in
internal SRAM. The object function allowlist and hashes join the C object
manifest. Audit requires the new IRQ entry points to reside in SRAM. This is
structural/source evidence, not a proof of isolation or arbitrary call graphs.
Task stack paint, guards, heap recovery and actual file CRC are checked on the
physical device for the exact image.

## Scope

`NIHOS_NATIVE_STORAGE_SERVICE=1` requires the read-only storage fixture,
4-bit/20 MHz SD profile and SQLite image layout. It is disabled by default.
The qualification creates and reaps real native tasks and uses existing task
calls and IPIs. It is not an untrusted userspace syscall ABI: tasks still share
machine-mode address space, the endpoint has one trusted client, and no path
permissions or multi-client service API are exposed. Root listing is bounded
to 128 entries; the fixture selects a non-empty file no larger than 64 KiB.
Write/format APIs remain absent.
