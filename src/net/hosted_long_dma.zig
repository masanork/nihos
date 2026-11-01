//! Experimental write-only DMA storage model. Not connected to the native Bus.
//! Cache operations and bus addresses are supplied by an external backend.
pub const State = enum { idle, prepared, retired };
const owned = @as(u32, 1) << 31;
const error_summary = @as(u32, 1) << 30;

pub const Buffer = struct {
    data: [1536]u8 align(64) = @splat(0),
    descriptor: [16]u32 align(64) = @splat(0),
    state: State = .idle,

    /// A backend supplies stable DMA addresses, cache operations, and a fence.
    /// It must serialize its cache operations against other ROM cache users.
    /// Once prepared, the object must remain fixed in memory until completion.
    pub fn prepare(self: *Buffer, bytes: []const u8, backend: anytype) ?u32 {
        if (self.state != .idle) return null;
        if (bytes.len != 1024 and bytes.len != 1536) return null;
        const data_address = backend.address(&self.data) orelse return null;
        const descriptor_address = backend.address(&self.descriptor) orelse return null;
        @memset(&self.data, 0);
        @memcpy(self.data[0..bytes.len], bytes);
        self.descriptor = @splat(0);
        self.descriptor[0] = owned | (1 << 4) | (1 << 3) | (1 << 2);
        self.descriptor[1] = @intCast(bytes.len);
        self.descriptor[2] = data_address;
        // Treat even a partially completed cache operation as ambiguous.
        self.state = .retired;
        if (!backend.writeback(@intFromPtr(&self.data), bytes.len) or
            !backend.writeback(@intFromPtr(&self.descriptor), 64)) return null;
        backend.fence();
        self.state = .prepared;
        return descriptor_address;
    }

    /// Call only after the controller has proved DMA is stopped. Ownership is
    /// read after descriptor invalidation; any ambiguity permanently retires.
    pub fn finish(self: *Buffer, backend: anytype) bool {
        if (self.state != .prepared) return false;
        self.state = .retired;
        backend.fence();
        if (!backend.invalidate(@intFromPtr(&self.descriptor), 64)) return false;
        const flags = @as(*volatile u32, &self.descriptor[0]).*;
        if (flags & (owned | error_summary) != 0) return false;
        self.state = .idle;
        return true;
    }

    /// Controller failure or reset quarantines the storage; this is not a
    /// proof that DMA stopped, and the object must stay alive until it does.
    pub fn retire(self: *Buffer) void {
        self.state = .retired;
    }
};
