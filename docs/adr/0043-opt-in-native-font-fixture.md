# 0043: Opt-in native font execution with task-owned extents

Status: accepted for local emulator and structural image qualification,
2026-10-28. Physical qualification remains pending.

Add a separate `graphics` qualification profile. Keep library code/RO in a
manifest-restricted Flash extension, private writable data in its own 32 KiB
internal-SRAM region and one 32 KiB font stack beside the retained 56 KiB stack
bank. Retain the ordinary 48 KiB primary heap minimum. Audit the actual loader
and revision-specific cache/SRAM windows for both profiles. Clear additional
BSS in native CRT.

Use full, unmodified pinned fonts as Flash inputs in an isolated 12 MiB factory
partition. Pad section transitions so the stock loader sees exactly two mapped
spans. This is a temporary qualification input, not production provisioning.

Privatize library/libc/compiler-helper definitions before linking. Only the
fixture entry, result and execution-PC globals remain public. Kernel helpers
stay in SRAM; reject dynamic initializers and TLS.

Opt into bounded extent groups only in this profile. The C++ pool obtains
children through the existing live heap/current task key. No font request can
reinitialize a heap. Root/child metadata operations use bounded local IRQ
masking; library work remains preemptible. Reject foreign tasks, IRQ dispatch
and invalid pointer operations before accepting an allocation/free.

After normal native qualification, admit the font task through the existing
runtime/dispatcher. Timer interrupts must capture it while bootstrap continues.
Compare all 16 hashes with the host; close clients, return through native EXIT
and drain/reap only after full cleanup. This test ends the library lifetime
and never attempts to reuse its HarfBuzz globals.

[Native graphics notes](../native-graphics.md) record fixed/demand memory,
the rejected three-mapping image and remaining storage/service-lifetime/
physical gates. Main integration and publication do not follow from these
emulator/build results.
