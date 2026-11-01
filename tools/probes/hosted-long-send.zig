//! RV32 codegen fixture only. Never run on hardware.
const sender = @import("hosted_long_sender");
const sd = @import("sdio");
const guard = @import("hosted_long_dma_guard");
const cache = @import("hosted_long_cache");

const Io = struct {
    buffer: *guard.Buffer = &dma_buffer,
    backend: cache.Rom = .{ .ops = .{} },
    pub fn read(_: *@This(), _: usize) u32 {
        return 0;
    }
    pub fn write(_: *@This(), _: usize, _: u32) void {}
    pub fn delay(_: *@This(), _: u32) void {}
    pub fn prepareDma(self: *@This(), writing: bool, source: []const u8, length: usize) ?u32 {
        if (!writing or source.len != length) return null;
        return self.buffer.prepare(source, &self.backend);
    }
    pub fn finishDma(self: *@This(), writing: bool, destination: []u8) bool {
        if (!writing or destination.len != 0) return false;
        return self.buffer.finish(&self.backend);
    }
};
const Host = struct {
    pub const TransportError = sd.Error;
    controller: sd.Controller(*Io),
    pub fn readWord(_: *@This(), _: u32) TransportError!u32 {
        return 1 << 16; // Stubbed credit source, not a real SDIO read.
    }
    pub fn writeBlocks(self: *@This(), address: u32, bytes: []const u8) TransportError!void {
        return self.controller.writeBlocks(address, bytes);
    }
};

var dma_buffer: guard.Buffer linksection(".hosted_dma") = .{};
export const nih_hosted_long_dma_layout: extern struct {
    data: *[1536]u8,
    bytes: u32,
    descriptor: *[16]u32,
    descriptor_bytes: u32,
} = .{
    .data = &dma_buffer.data,
    .bytes = 1536,
    .descriptor = &dma_buffer.descriptor,
    .descriptor_bytes = 64,
};
var io: Io = .{};
var host: Host = .{ .controller = .{ .io = &io } };
var guarded: guard.Guard(Host) = .{ .host = &host, .buffer = &dma_buffer };
var stream: sender.ProfileStream(@TypeOf(guarded), 64) = .{ .host = &guarded };
var owner: sender.Sender(@TypeOf(guarded), 64) = .{ .stream = &stream };

export fn nih_hosted_long_send_compile_probe(bytes: [*]const u8, length: usize, ready: bool) usize {
    // Dynamic fixture input retains the controller path in optimized links.
    // This is not controller enumeration and must never run on a device.
    _ = &nih_hosted_long_dma_layout;
    host.controller.prepared = ready;
    host.controller.selected = ready;
    host.controller.four_bit = ready;
    return owner.send(bytes[0..length]) catch 0;
}

// Retain both ROM call paths even if optimization elides an inert controller.
export fn nih_hosted_long_dma_prepare_probe(bytes: [*]const u8, length: usize) u32 {
    return dma_buffer.prepare(bytes[0..length], &io.backend) orelse 0;
}
export fn nih_hosted_long_dma_finish_probe() bool {
    return dma_buffer.finish(&io.backend);
}
