//! Host-only separate geometry; never linked into the native 4 MiB owner.
pub const nih_store_probe_capacity = 32 * 1024 * 1024;
comptime {
    if (@import("builtin").os.tag == .freestanding) @compileError("32 MiB probe is host-only");
    _ = @import("store_abi.zig");
}
