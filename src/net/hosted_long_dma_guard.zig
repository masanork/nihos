//! Experimental host wrapper: quarantine the associated DMA storage whenever
//! the underlying controller reports an ambiguous multi-block failure.
const dma = @import("hosted_long_dma.zig");
pub const Buffer = dma.Buffer;

/// Host's writeBlocks must use this exact Buffer as its DMA storage. Calls to
/// the underlying host must be serialized by the same external owner; bypass
/// of this guard defeats its quarantine. This wrapper does not stop hardware.
pub fn Guard(comptime Host: type) type {
    return struct {
        host: *Host,
        buffer: *dma.Buffer,
        pub const TransportError = Host.TransportError;

        pub fn readWord(self: *@This(), address: u32) TransportError!u32 {
            return self.host.readWord(address);
        }

        pub fn writeWord(self: *@This(), address: u32, value: u32) TransportError!void {
            return self.host.writeWord(address, value);
        }

        pub fn readBytes(self: *@This(), address: u32, destination: []u8) TransportError!void {
            return self.host.readBytes(address, destination);
        }

        pub fn writeBytes(self: *@This(), address: u32, bytes: []const u8) TransportError!void {
            return self.host.writeBytes(address, bytes);
        }

        pub fn writeBlocks(self: *@This(), address: u32, bytes: []const u8) TransportError!void {
            self.host.writeBlocks(address, bytes) catch |err| {
                self.buffer.retire();
                return err;
            };
        }
    };
}
