//! Host-testable long-packet staging ownership model; not a native DMA driver.
const plan = @import("hosted_tx_plan.zig");

pub const Error = plan.Error || error{ Busy, Retired, Cache, StillOwned, InvalidState };
pub const State = enum { idle, prepared, retired };

pub const Staging = struct {
    bytes: [1536]u8 align(64) = @splat(0),
    state: State = .idle,
    wire_len: usize = 0,

    /// `cache` must write back exactly the supplied aligned owned buffer.
    /// Ownership moves to DMA only after this operation succeeds.
    pub fn prepare(self: *Staging, payload: []const u8, cache: anytype) Error!plan.Plan {
        if (self.state == .retired) return error.Retired;
        if (self.state != .idle) return error.Busy;
        const result = try plan.longPacket(payload.len);
        @memset(&self.bytes, 0);
        @memcpy(self.bytes[0..payload.len], payload);
        if (!cache.writeback(self.bytes[0..result.wire])) {
            self.state = .retired;
            return error.Cache;
        }
        self.wire_len = result.wire;
        self.state = .prepared;
        return result;
    }

    /// Completion must be based on an invalidated descriptor, and the DMA
    /// engine must be quiescent before this buffer can be reused.
    pub fn complete(self: *Staging, quiescent: bool, cache: anytype) Error!void {
        if (self.state == .retired) return error.Retired;
        if (self.state != .prepared) return error.InvalidState;
        if (!cache.invalidateDescriptor()) {
            self.state = .retired;
            return error.Cache;
        }
        if (cache.descriptorOwned() or !quiescent) {
            self.state = .retired;
            return error.StillOwned;
        }
        self.state = .idle;
        self.wire_len = 0;
    }

    /// A timeout or ambiguous transfer permanently quarantines the buffer.
    pub fn fail(self: *Staging) void {
        self.state = .retired;
    }
};
