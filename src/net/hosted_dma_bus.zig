//! Experimental exclusive-owner adapter: retain the existing short DMA path
//! for register reads and small packets; route long writes to private storage.
const dma = @import("hosted_long_dma.zig");
pub const Buffer = dma.Buffer;
pub const Active = enum { none, short, long, retired };

pub fn Bus(comptime Short: type, comptime Cache: type) type {
    return struct {
        short: Short,
        buffer: *Buffer,
        cache: Cache,
        active: Active = .none,
        pub fn read(self: *@This(), address: usize) u32 {
            return self.short.read(address);
        }
        pub fn write(self: *@This(), address: usize, value: u32) void {
            self.short.write(address, value);
        }
        pub fn delay(self: *@This(), us: u32) void {
            self.short.delay(us);
        }
        pub fn fourBitPins(self: *@This()) void {
            self.short.fourBitPins();
        }

        pub fn prepareDma(self: *@This(), writing: bool, source: []const u8, length: usize) ?u32 {
            if (self.active != .none or self.buffer.state == .retired) return null;
            if (length == 0 or length % 4 != 0 or
                (writing and source.len != length) or (!writing and source.len != 0)) return null;
            if (length <= 512) {
                const descriptor = self.short.prepareDma(writing, source, length) orelse return null;
                self.active = .short;
                return descriptor;
            }
            if (!writing or source.len != length) return null;
            const descriptor = self.buffer.prepare(source, &self.cache) orelse {
                if (self.buffer.state == .retired) self.active = .retired;
                return null;
            };
            self.active = .long;
            return descriptor;
        }

        /// Controller must stop DMA before calling this. Timeout paths skip
        /// this call and retain active storage; the owner must retire the host.
        pub fn finishDma(self: *@This(), writing: bool, destination: []u8) bool {
            const ok = switch (self.active) {
                .short => self.short.finishDma(writing, destination),
                .long => writing and destination.len == 0 and self.buffer.finish(&self.cache),
                else => return false,
            };
            self.active = if (ok) .none else .retired;
            if (!ok) self.buffer.retire();
            return ok;
        }
    };
}
