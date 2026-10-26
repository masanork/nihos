//! ESP32-C6 SDIO stream counters/FIFO addressing, independent of ESP-Hosted.
//! Requires a freshly reset peer and function 1 configured for 512-byte buffers.
pub const fifo_end: u32 = 0x1f800;
pub const token_register: u32 = 0x44;
pub const length_register: u32 = 0x60;
pub const interrupt_clear: u32 = 0xd4;
pub const rx_mask: u32 = 0xfffff;
pub const credit_mask: u32 = 0xfff;
pub const max_credits = 10; // Pinned C6 CONFIG_AT_SDIO_BUFFER_NUM.
pub const backlog_limit = 128 * 1024;
pub const Error = error{ Retired, CounterDiscontinuity, InvalidBuffer };

pub const Plan = struct { address: u32, logical: usize, wire: usize };
pub fn plan(length: usize) Error!Plan {
    if (length == 0 or length > 512) return error.InvalidBuffer;
    return .{ .address = fifo_end - @as(u32, @intCast(length)), .logical = length, .wire = (length + 3) & ~@as(usize, 3) };
}

pub fn Stream(comptime Host: type) type {
    return struct {
        host: *Host,
        received: u32 = 0,
        sent_buffers: u32 = 0,
        faulted: bool = false,
        scratch: [512]u8 = @splat(0),
        const Self = @This();
        const StreamError = Error || Host.TransportError;

        /// The caller must reset C6 when recreating this state. Rebasing these
        /// counters onto live hardware would silently drop bytes or TX credits.
        pub fn receive(self: *Self, destination: []u8) StreamError!usize {
            if (self.faulted) return error.Retired;
            if (destination.len == 0) return error.InvalidBuffer;
            errdefer self.faulted = true;
            const total = (try self.host.readWord(length_register)) & rx_mask;
            const available = (total -% self.received) & rx_mask;
            if (available > backlog_limit) return error.CounterDiscontinuity;
            if (available == 0) return 0;
            const transfer = try plan(@min(available, @min(destination.len, 512)));
            try self.host.readBytes(transfer.address, self.scratch[0..transfer.wire]);
            self.received = (self.received + @as(u32, @intCast(transfer.logical))) & rx_mask;
            try self.host.writeWord(interrupt_clear, 0xffffffff);
            @memcpy(destination[0..transfer.logical], self.scratch[0..transfer.logical]);
            return transfer.logical;
        }

        /// At most one C6 receive buffer per call. Zero credits means no
        /// progress, not a retry loop; the AT owner's deadline still applies.
        pub fn send(self: *Self, source: []const u8) StreamError!usize {
            if (self.faulted) return error.Retired;
            if (source.len == 0) return error.InvalidBuffer;
            errdefer self.faulted = true;
            const total = ((try self.host.readWord(token_register)) >> 16) & credit_mask;
            const credits = (total -% self.sent_buffers) & credit_mask;
            if (credits > max_credits) return error.CounterDiscontinuity;
            if (credits == 0) return 0;
            const transfer = try plan(@min(source.len, 512));
            @memset(&self.scratch, 0);
            @memcpy(self.scratch[0..transfer.logical], source[0..transfer.logical]);
            try self.host.writeBytes(transfer.address, self.scratch[0..transfer.wire]);
            self.sent_buffers = (self.sent_buffers + 1) & credit_mask;
            return transfer.logical;
        }

        pub fn invalidate(self: *Self) void {
            self.faulted = true;
        }
    };
}
