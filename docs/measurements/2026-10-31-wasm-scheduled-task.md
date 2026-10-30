# Scheduled RV32 Wasm task and same-boot recovery

The opt-in headless emulator now runs the signed Rust Wasm sample in a normal
OS-registered task. This completes the scheduler/leased-stack part of the Rust
SDK landing gate. The common foreground session and physical display path are
still separate work.

## Execution and ownership

`NIHOS_NATIVE_WASM_TASK=1` is restricted to emulator Wasm mode with headless
`BOOT_TEST=1`. The option defaults off and is rejected for device images.
`probes/wamr-native/run-task-emulator.sh` builds and audits the candidate and
rejects a linked `nih_wamr_call` boot SP-switch entry.

CPU0 bootstrap owns a pinned PSRAM lease and lends its 64 KiB stack to one
generation-qualified task. Registration requires bootstrap identity, its pin
owner, normal phase and enabled interrupts. A duplicate live registration is
rejected. The task enters through the normal saved context/trampoline; guest
execution keeps interrupts enabled. Its child resource ledger is cleaned on
exit. Bootstrap then reaps the task, removes the stack binding, checks stack
guards, wipes the entire lease, and releases the parent pin. Ordinary free
rejects the pinned allocation.

Interrupt admission checks the existing SRAM dispatcher-stack guard first,
then the current task slot/generation, CPU0, M-mode status, aligned complete
128-byte frame, matching saved SP and registered bounds. The admission helper
does not scan PSRAM guards on the IRQ stack. Trap entry and context handling
necessarily access the interrupted frame in PSRAM: this is not cache-off or
physical interrupt qualification. Wrong hart, generation, privilege, bounds,
alignment and overflowing allocation ranges have host unit coverage.

The foreground polls at most one ROM UART byte per service turn. The child
waits through `waitEvents`, and bootstrap queues input and notifies that exact
handle. A 500 ms fixture timeout wakes a no-input task for cooperative cleanup.
This does not implement arbitrary forced termination inside WAMR.

## Repeatable evidence

Each unchanged candidate runs three emulator cases. Round one receives external
`0x10q`, no input, or early `q`, producing statuses 0, 42 and 44 respectively.
After cleanup, round two reuses the same backing address with a new task
generation and synthetic `0x10q`. A notification to the retired handle is
rejected. Both rounds check arena recovery, surface/stack guards, owner release,
heap recovery, timer captures and input waits.

The repeat test exposed an allocator lifecycle defect: the two WAMR arenas
remained initialized after all objects were freed, so a second engine start
failed. The new deinitialization operation refuses live or damaged arenas and
detaches borrowed regions only after both arenas fully recover. Unit coverage
checks refusal with live objects, access after detach and reinitialization.

Across all six task executions the requested lease is 499,712 bytes (488 KiB),
the buddy allocator charges 524,288 bytes (512 KiB), and observed stack use is
23,792 bytes of 65,536. Every execution recovers the entire charged capacity.
The first rounds capture 111 task timer interrupts; restart rounds capture 112.
Both hart counters advance in every run. These numbers are emulator
observations, not device sizing or timing qualification.

The retained identity record binds logs, parsed reports and image hashes to
the local implementation commit:
[evidence identity](evidence/2026-10-31-wasm-scheduled-task/identity.json).
The manual CI workflow includes the new runner; remote CI has not been run.

## Remaining boundary

The scheduled task still executes a monolithic test runner with a private
surface. Next, expose bounded open/render/close task requests to the existing
common session, publish through its presenter, and preserve console/camera
ownership and cancellation. No normal UI Wasm backend, physical scanout,
hardware input, cache-off behavior, production trust/counters or persistent
installation is claimed. WAMR alignment adoption remains unresolved before
enabling a device profile. Publication and merge remain gated on exact-candidate
physical qualification and required CI.
