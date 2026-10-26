//! Read-only loader-mapped diagnostic tables; no Flash controller writes.
extern var __flash_records_start: u8;
extern var __flash_records_end: u8;

pub const Report = struct {
    start: u32 = 0,
    end: u32 = 0,
    bytes: u32 = 0,
    initial: u32 = 0,
    final: u32 = 0,
    checks: u32 = 0,
    confirmed: u32 = 0,
};
var reports: [2]Report = .{ .{}, .{} };

noinline fn checksum(start: u32, length: u32) u32 {
    const bytes: [*]const volatile u8 = @ptrFromInt(start);
    var value: u32 = 2166136261;
    for (0..length) |index| value = (value ^ bytes[index]) *% 16777619;
    return value;
}

pub noinline fn begin(core: u32) bool {
    if (core >= 2) return false;
    const start = @intFromPtr(&__flash_records_start);
    const end = @intFromPtr(&__flash_records_end);
    if (start != 0x40010020 or end <= start or end > 0x40020000) return false;
    const owner = &reports[core];
    if (owner.bytes != 0) return false;
    owner.* = .{ .start = start, .end = end, .bytes = end - start, .initial = checksum(start, end - start), .checks = end - start };
    return true;
}

/// Owner bootstrap only, before its final memory publication. No payload
/// or mapping may change between begin and finish.
pub noinline fn finish(core: u32) bool {
    if (core >= 2) return false;
    const owner = &reports[core];
    if (owner.bytes == 0 or owner.confirmed != 0) return false;
    owner.final = checksum(owner.start, owner.bytes);
    if (owner.final != owner.initial) return false;
    owner.checks += owner.bytes;
    @atomicStore(u32, &owner.confirmed, 1, .release);
    return true;
}

pub fn report(core: u32) Report {
    if (core >= 2 or @atomicLoad(u32, &reports[core].confirmed, .acquire) != 1) return .{};
    return reports[core];
}
