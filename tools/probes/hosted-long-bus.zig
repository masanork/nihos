//! Real Bus/cache codegen only. No power/reset/pads/startup; never run directly.
const native = @import("c6_probe");
const adapter = @import("hosted_dma_bus");
const cache = @import("hosted_long_cache");
const sd = @import("sdio");
const sender = @import("hosted_long_sender");

const Io = adapter.Bus(native.Bus, cache.Rom);
var buffer: adapter.Buffer = .{};
var io: Io = .{ .short = .{}, .buffer = &buffer, .cache = .{ .ops = .{} } };
const Host = struct {
    pub const TransportError = sd.Error;
    controller: sd.Controller(*Io) = .{ .io = &io },
    pub fn readWord(self: *@This(), address: u32) TransportError!u32 {
        return self.controller.readWord(address);
    }
    pub fn writeBlocks(self: *@This(), address: u32, bytes: []const u8) TransportError!void {
        self.controller.writeBlocks(address, bytes) catch |err| {
            buffer.retire();
            return err;
        };
    }
};
var host: Host = .{};
var stream = sender.ProfileStream(Host, 64){ .host = &host };
var tx = sender.Sender(Host, 64){ .stream = &stream };

export fn nih_hosted_long_bus_compile_init(exclusive: bool) bool {
    host.controller.prepare(exclusive) catch return false;
    host.controller.identify() catch return false;
    host.controller.enableFunction() catch return false;
    return true;
}
export fn nih_hosted_long_bus_compile_send(bytes: [*]const u8, length: usize) usize {
    return tx.send(bytes[0..length]) catch 0;
}

// Compile the shared-host ownership and detach contract as well as the
// existing exclusive fixture. This probe never executes on a target.
export fn nih_hosted_long_bus_compile_shared() bool {
    host.controller.prepareShared() catch return false;
    return true;
}
