# 0033: Whitelisted Flash boot code

Status: accepted for native emulation; physical qualification pending, 2026-10-26.

## Placement

Move only CPU0's one-time PSRAM discovery/setup function and its mapping
preparation function to `.flash.boot`. They run before CPU1 release and before
the scheduler timers start. They retain their existing bounded command polls,
timer lease, PSRAM register/MMU1 setup, ROM cache calls and error returns.
The code placement does not introduce Flash erase/program operations, change
Flash MMU0, resize caches, change frequencies or add a ROM ABI entry.

Pinned ESP-IDF v5.4.4
[memory definitions](https://github.com/espressif/esp-idf/blob/v5.4.4/components/esp_system/ld/esp32p4/memory.ld.in)
provide an RX Flash instruction region beginning at `0x40000020`. Its
[loader](https://github.com/espressif/esp-idf/blob/v5.4.4/components/bootloader_support/src/bootloader_utility.c)
maps two external segments and enables the buses before entering the app.
Use that existing first mapping for the descriptor followed by boot code:

| ELF section | Virtual start | Constraint |
| --- | --- | --- |
| `.flash.appdesc` | `0x40000020` | Exactly 256 read-only bytes |
| `.flash.boot` | `0x40000120` | RX, at most 65,248 bytes, within the first 64 KiB page |
| `.flash.rodata` | `0x40010020` | Read-only normal record tables, within the second page |

The image tool merges the adjacent descriptor and boot-code sections into
one mapped image segment. The table section remains the second mapped
segment. No third external image segment is permitted. The app entry, CPU1
entry, trap path, scheduler, allocator operations, stacks, ordinary constants
and mutable state remain in the existing resident SRAM region. The boot
functions can call resident helpers and ROM routines; moving a function does
not move all of its dependencies implicitly.

## ELF and image contracts

Only `psram.probe` and the compiler's numeric instantiation of
`psram_memory.prepare` may have Flash function addresses. Require exactly
one of each role, nonzero in-range extents, no overlap, and no more than
16 bytes of alignment between them. The pair must cover the section's outer
extent. All other function symbols must be resident or match the existing
ROM ABI. Flash code must be executable/read-only PROGBITS and fit its page;
metadata and table sections must remain non-executable/read-only PROGBITS.

Run the existing instruction scan over Flash boot code too. No FP instruction
is allowed there, including in the compiled ILP32F profile; FP instructions
retain their approved task/helper boundaries. The app entry and all prior
heap, stack, loader-overlap, cache/revision and unresolved-symbol gates remain.

The first image segment must contain exactly the descriptor plus rounded
boot-code bytes. Compare those bytes with the ELF's `.flash.boot`, validate
the descriptor's ELF SHA256 and explicit 64 KiB MMU page size, and retain
the code digest, extent and both function-role ranges in the image audit.
Continue requiring exactly two mapped segments and congruent virtual/image
offsets. With the factory app at `0x10000`, boot instructions start at physical
Flash `0x10120`. All nine smoke cases retain and execute their exact images
as established by ADR 0032.

This is a section/symbol/instruction contract for the built fixture, not a
general call-graph, reentrancy or memory-isolation proof. Current source has
one CPU0 call to the probe and a mapping call only after successful discovery
and command tests. Later cache-off or service code must not reuse these boot
functions while their mappings/cache dependency is unavailable.

## Execution evidence

Each placed function obtains its current PC with `auipc` and returns it in
its existing report. After probe return, CPU0 emits one
`NIHOS_NATIVE_BOOT_CODE` record containing the linked section start/end,
probe PC, mapping PC and completed flag. The new fields use an explicitly
typed runtime struct, preserving the typed record writer's schema rules.

The log validator requires exactly one completed record. The probe PC must
be a halfword-aligned Flash address. A populated die must also have a distinct
aligned mapping PC; an absent die must report zero for the uncalled mapping
function. When supplied the case's image audit, both PCs must fall within
their individual approved function ranges and the section extent must match.
These PCs demonstrate where those points executed; they are not a secure
attestation or proof that every instruction was fetched from physical Flash.

Successful execution still requires the complete 300-round SMP/preemption,
normal/forced lifecycle, IPI-only idle, FP, SRAM, PSRAM/cache/command,
heap-recovery and task-pool gates. Initial/final full-table Flash reads from
both harts remain mandatory and bound to each saved image. No-PSRAM cases
qualify execution of the discovery function without claiming mapping work.

## Budget and next boundary

Record net resident savings including added PC/report code, report fields,
normal table text and alignment. Keep the 48 KiB internal heap gate, all
stack sizes, safe compilation, task quotas, cache geometry and clock policy.
This creates room for the next service/allocator work without registering a
new SRAM bank or weakening an existing minimum.

Only boot-only code is placed here. General service/task execution from
Flash, interrupt-safe Flash dependencies, cache-off SMP coordination,
erase/program, physical fetch timing and cache-miss/eviction behavior remain
separate qualification. Direct trap/error output still uses resident code
and ordinary SRAM literals. No device, power, DMA or FPS result is claimed.
