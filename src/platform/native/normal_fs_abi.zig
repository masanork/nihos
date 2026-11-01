//! Trusted CPU0 foreground API. No hardware work follows from a request
//! until the service task owns the host; all request bytes are copied.
pub const Status = enum(u32) { off, starting, mounted, no_card, rejected, no_memory, quarantined, owned_store };
pub const Report = extern struct {
    status: Status = .off,
    generation: u32 = 0,
    kind: u32 = 0,
    sectors: u32 = 0,
    requests: u32 = 0,
    completed: u32 = 0,
    bytes: u32 = 0,
    crc: u32 = 0,
    eof: u32 = 0,
    error_code: i32 = 0,
    io_reads: u32 = 0,
    yields: u32 = 0,
    parent_start: u32 = 0,
    parent_bytes: u32 = 0,
    io_error: u32 = 0,
    command: u32 = 0,
    interrupts: u32 = 0,
    dma_status: u32 = 0,
};
extern fn nih_normal_fs_begin(u32) callconv(.c) void;
extern fn nih_normal_fs_submit(u32, [*]const u8, u32) callconv(.c) u32;
extern fn nih_normal_fs_poll(u32) callconv(.c) u32;
extern fn nih_normal_fs_snapshot(*Report) callconv(.c) void;
extern fn nih_normal_fs_result(u32, [*]u8, u32) callconv(.c) u32;
pub fn begin(client: u32) void {
    nih_normal_fs_begin(client);
}
pub fn submit(client: u32, path: []const u8) bool {
    return nih_normal_fs_submit(client, path.ptr, @intCast(path.len)) == 1;
}
pub fn poll(client: u32) bool {
    return nih_normal_fs_poll(client) == 1;
}
pub fn snapshot() Report {
    var report = Report{};
    nih_normal_fs_snapshot(&report);
    return report;
}
pub fn result(offset: u32, destination: []u8) u32 {
    return nih_normal_fs_result(offset, destination.ptr, @intCast(destination.len));
}
