//! RV32 code-generation probe only; never allocate or touch SRAM on a target.
const native = @import("native_long_storage");
var pool: native.Pool = .{};
var owner: native.Owner = .{};

export fn nih_long_storage_reserve_compile() bool {
    owner.reserve(&pool) catch return false;
    return owner.buffer() != null;
}
export fn nih_long_storage_retire_compile() void {
    owner.retire();
}
