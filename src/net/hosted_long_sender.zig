//! Host-tested long Hosted write coordinator; not wired to native networking.
const sdio = @import("c6_sdio.zig");
const plan = @import("hosted_tx_plan.zig");
pub const ProfileStream = sdio.ProfileStream;
pub const Stream = sdio.Stream;

/// The caller must serialize this with all other C6 traffic. Short and long
/// sends use the same stream counters and fault state. `host.writeBlocks` must report errors whenever
/// DMA completion or quiescence is unproved. It must no longer access the
/// source after success. After failure, the caller must keep this object and
/// any Host DMA storage alive until hardware quiescence is separately proved.
/// A reset must retire this object.
pub fn Sender(comptime Host: type, comptime credit_limit: u32) type {
    return struct {
        stream: *sdio.ProfileStream(Host, credit_limit),
        // CPU-only padding buffer. The Host owns its separate DMA buffer,
        // descriptor, cache maintenance, and completion checks.
        buffer: [1536]u8 = @splat(0),
        retired: bool = false,
        const Self = @This();
        const Error = Host.TransportError || sdio.Error || plan.Error;

        pub fn send(self: *Self, packet: []const u8) Error!usize {
            if (self.retired or self.stream.faulted) return error.Retired;
            // Reject malformed inputs before reading credits or touching DMA.
            _ = try plan.longPacket(packet.len);
            return self.stream.sendLong(packet, &self.buffer) catch |err| {
                self.retire();
                return err;
            };
        }

        pub fn retire(self: *Self) void {
            self.retired = true;
            self.stream.invalidate();
        }
    };
}
