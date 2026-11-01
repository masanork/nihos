//! Symbol-closure probe only. It is not a nihos task or bootable image.
const runtime_bytes = 128 * 1024;
const linear_bytes = 256 * 1024;
var runtime_arena: [runtime_bytes]u8 align(64) = undefined;
var linear_arena: [linear_bytes]u8 align(64) = undefined;
var probe_stack: [16 * 1024]u8 align(16) = undefined;
const wasm_header = [_]u8{ 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00 };

extern fn nih_wamr_rv32_link_inventory(
    wasm: [*]const u8,
    length: u32,
    runtime: [*]u8,
    linear: [*]u8,
) callconv(.c) void;

/// Link-only placeholder. A real owner must connect the kernel monotonic clock.
export fn nih_wamr_monotonic_us() callconv(.c) u64 {
    return 0;
}

/// Link-only placeholder region. This is not the executing task's stack proof.
export fn nih_wamr_stack_boundary() callconv(.c) [*]u8 {
    return &probe_stack;
}

export fn nih_wamr_closed_link_probe() callconv(.c) noreturn {
    nih_wamr_rv32_link_inventory(&wasm_header, @intCast(wasm_header.len), &runtime_arena, &linear_arena);
    while (true) asm volatile ("nop");
}
