//! CPU0-only long DMA provider for the Network Split fixture.
const adapter = @import("hosted_dma_bus");
const cache = @import("hosted_long_cache");
pub var buffer: adapter.Buffer = .{};

pub fn C6Bus(comptime Short: type) type {
    return struct {
        routing: adapter.Bus(Short, cache.Rom) = .{ .short = .{}, .buffer = &buffer, .cache = .{ .ops = .{} } },
        pub fn setClock(self: *@This(), clock: anytype) void {
            self.routing.short.setClock(clock);
        }
        pub fn read(self: *@This(), address: usize) u32 {
            return self.routing.read(address);
        }
        pub fn write(self: *@This(), address: usize, value: u32) void {
            self.routing.write(address, value);
        }
        pub fn delay(self: *@This(), us: u32) void {
            self.routing.delay(us);
        }
        pub fn fourBitPins(self: *@This()) void {
            self.routing.fourBitPins();
        }
        pub fn prepareDma(self: *@This(), writing: bool, source: []const u8, length: usize) ?u32 {
            return self.routing.prepareDma(writing, source, length);
        }
        pub fn finishDma(self: *@This(), writing: bool, destination: []u8) bool {
            return self.routing.finishDma(writing, destination);
        }
    };
}
