//! Compile-only fixture. Its cache methods are inert; never run on hardware.
const dma = @import("hosted_long_dma");
const Backend = struct {
    pub fn address(_: *@This(), ptr: anytype) ?u32 {
        return @intCast(@intFromPtr(ptr));
    }
    pub fn writeback(_: *@This(), _: usize, _: usize) bool {
        return true;
    }
    pub fn invalidate(_: *@This(), _: usize, _: usize) bool {
        return true;
    }
    pub fn fence(_: *@This()) void {}
};
var buffer: dma.Buffer = .{};
var backend: Backend = .{};
export fn nih_hosted_long_dma_prepare(bytes: [*]const u8, length: usize) u32 {
    return buffer.prepare(bytes[0..length], &backend) orelse 0;
}
export fn nih_hosted_long_dma_finish() bool {
    return buffer.finish(&backend);
}
export fn nih_hosted_long_dma_retire() void {
    buffer.retire();
}
