//! Link-only RV32 fixture: no board startup, interrupts, input or scanout.
const adapter = @import("adapter");
extern fn nih_rust_app_frame(selected: u32) callconv(.c) i32;
extern fn nih_app_probe_attach(bytes: [*]u8, len: u32, width: u32, height: u32, stride: u32) callconv(.c) i32;
var pixels: [160 * 80 * 2]u8 = undefined;
export fn nih_rust_fixture_run() callconv(.c) i32 {
    _ = adapter;
    if (nih_app_probe_attach(&pixels, pixels.len, 160, 80, 320) != 0) return -1;
    return nih_rust_app_frame(1);
}
