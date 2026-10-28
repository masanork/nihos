//! Target-compilation contract only. Callers must supply exclusive heap ranges.
const dev = @import("development_memory");
var manager: dev.Manager = .{};
pub export const nih_broker_metadata_bytes: u32 = @sizeOf(dev.Manager);
export fn nih_broker_compile_contract(internal: [*]u8, external: [*]u8) u32 {
    if (!manager.init(&.{.{ .memory = internal[0..dev.internal_bytes] }}, &.{.{ .memory = external[0..dev.external_bytes] }}, dev.policy)) return 0;
    const owner = manager.open(.ime, .{ .internal = 8192, .external = 2097152 }) catch return 0;
    const lease = manager.alloc(owner, .external, 2097152, 64) catch return 0;
    const pin = manager.pin(owner, lease) catch return 0;
    manager.beginClose(owner) catch return 0;
    if ((manager.reclaimOne(owner) catch return 0) != .waiting) return 0;
    manager.unpin(pin.token) catch return 0;
    if ((manager.reclaimOne(owner) catch return 0) != .released) return 0;
    if ((manager.reclaimOne(owner) catch return 0) != .complete) return 0;
    if (manager.stats(.internal).free != dev.internal_bytes or manager.stats(.external).free != dev.external_bytes) return 0;
    return 1;
}
