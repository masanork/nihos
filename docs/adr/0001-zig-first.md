# ADR 0001: Zig-first implementation with a narrow C ABI

- Status: Accepted
- Date: 2026-10-25

## Context

nihos targets the M5Stack Tab5 and its ESP32-P4 revision 1.3. The operating
system should remain small, readable, useful for teaching, and able to use
ESP-IDF and licensed M5Stack implementations without importing their internal
types throughout the kernel.

The implementation language must support explicit MMIO, DMA, interrupts,
cache maintenance, SMP, and freestanding builds. It must also permit direct
use of selected C libraries while improving on C's unchecked pointer and error
handling.

## Decision

Use Zig 0.17.0 as the primary language for the kernel, HAL, VFS, and native
services.

- Keep assembly limited to reset, trap entry, and context switching where the
  architecture requires it.
- Keep C limited to vendor integration shims and independently licensed C
  libraries.
- Expose platform facilities through a small handwritten C ABI containing
  fixed-width values, opaque handles, and explicit ownership operations.
- Do not expose ESP-IDF, M5Unified, or M5GFX structures to kernel code.
- Permit Rust services or applications after the ABI is stable, but do not
  make Rust the kernel language for the initial Tab5 port.
- Pin the exact Zig release and verify the downloaded archive checksum.

## Why not C as the primary language?

C has the most direct ESP-IDF integration and remains the comparison baseline.
It does not express slices, optional values, explicit error sets, allocator
ownership, or exhaustive state transitions strongly enough for the intended
kernel and educational goals. Static analysis remains required at the C
boundary.

## Why not Rust as the primary language?

Rust provides the strongest memory and concurrency checks. At the time of this
decision, bare-metal `esp-hal` support for ESP32-P4 requires revision 3.0 or
newer, while the tested Tab5 contains revision 1.3 silicon. Rust can target the
P4 through ESP-IDF, but that path is less suitable for replacing the scheduler
and runtime.

Rust destructors also require a cooperative cancellation design. A kernel that
discards a task stack cannot assume that `Drop` ran. Rust remains valuable for
later services and for testing whether the language-neutral ABI is genuinely
usable.

## Safety policy

- Raw pointers are confined to `arch/`, `soc/`, `board/`, and `compat/`.
- Every MMIO access, pointer cast, DMA ownership transition, and interrupt
  shared-state operation carries a `SAFETY` comment describing its invariant.
- Normal firmware and all CI-equivalent local checks use `ReleaseSafe` or
  Debug. `ReleaseFast` is permitted only for measured, reviewed hot paths.
- Public kernel interfaces use slices, tagged unions, bounded queues, and
  explicit error sets rather than sentinel values.
- Cross-core data uses explicit atomics or locks; Zig's type system is not
  treated as a data-race detector.

## Validation gate

Before target-specific kernel work grows, maintain equivalent C, Zig, and Rust
implementations of a small ABI probe. On Tab5, compare a fixed workload for:

- linked Flash text and read-only data;
- static internal RAM and per-task stack;
- timer and IPC latency;
- CPU0/CPU1 ring throughput;
- framebuffer fill and cache synchronization;
- batched block I/O;
- amount of handwritten unsafe or raw-pointer code.

Zig remains the default unless it shows a material, unexplained regression
against C. Individual hot paths may remain in C or assembly without changing
the kernel language.

## Consequences

The project accepts Zig pre-1.0 source migration costs and must pin its
toolchain. In return, the OS keeps a small runtime model and direct C ABI while
gaining clearer errors, bounds, allocation, and compile-time configuration.
