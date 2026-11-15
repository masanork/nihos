//! Host model of the normal FS bounded read. One owner drives each request and
//! response; the destination remains private until `complete`. On a transport
//! or correlation failure the caller must stop the lane before reusing it.
const multi = @import("vfs_multi_writer.zig");

pub const Progress = enum { request, complete, stop_lane };
pub const Reader = struct {
    const Phase = enum { idle, open, read, close, done };
    phase: Phase = .idle,
    session: u64 = 0,
    epoch: u32 = 0,
    sequence: u32 = 0,
    file: ?multi.Handle = null,
    bytes: usize = 0,
    eof: bool = false,
    output: []u8 = &.{},

    fn wipe(self: *Reader) void {
        @memset(self.output, 0);
        self.bytes = 0;
        self.eof = false;
    }
    fn stopLane(self: *Reader) Progress {
        self.wipe();
        self.phase = .done;
        return .stop_lane;
    }
    fn next(self: *Reader, req: *multi.Request, operation: multi.Operation) bool {
        if (self.sequence == 0xffffffff) return false;
        self.sequence += 1;
        req.* = .{ .session = self.session, .epoch = self.epoch, .sequence = self.sequence, .operation = operation };
        return true;
    }
    /// `sequence` is the last sequence sent on the lane. `output` must not be
    /// exposed, changed or reused before a terminal result or a stopped lane.
    pub fn begin(self: *Reader, session: u64, epoch: u32, sequence: u32, path: []const u8, output: []u8, req: *multi.Request) bool {
        if (self.phase != .idle or session == 0 or epoch == 0 or sequence == 0xffffffff or path.len == 0 or path.len > 511 or output.len == 0 or output.len > 4096) return false;
        self.session = session;
        self.epoch = epoch;
        self.sequence = sequence;
        self.output = output;
        self.wipe();
        self.phase = .open;
        _ = self.next(req, .open);
        req.rights = .{ .read = true };
        req.path_length = @intCast(path.len);
        @memcpy(req.path[0..path.len], path);
        return true;
    }
    fn readRequest(self: *Reader, req: *multi.Request) Progress {
        if (!self.next(req, .read)) return self.stopLane();
        self.phase = .read;
        req.handle = self.file;
        req.offset = self.bytes;
        req.length = @intCast(@min(multi.transfer_bytes, self.output.len - self.bytes));
        return .request;
    }
    fn closeRequest(self: *Reader, req: *multi.Request) Progress {
        if (!self.next(req, .close)) return self.stopLane();
        self.phase = .close;
        req.handle = self.file;
        return .request;
    }
    /// Consume exactly one matching reply for the outstanding request.
    pub fn accept(self: *Reader, response: *const multi.Response, req: *multi.Request) Progress {
        if (self.phase == .idle or self.phase == .done or response.session != self.session or response.epoch != self.epoch or response.sequence != self.sequence) return self.stopLane();
        switch (self.phase) {
            .open => switch (response.result) {
                .handle => |handle| {
                    if (handle.session != self.session or handle.token == 0) return self.stopLane();
                    self.file = handle;
                    return self.readRequest(req);
                },
                .failure => return self.stopLane(),
                else => return self.stopLane(),
            },
            .read => switch (response.result) {
                .transfer => |transfer| {
                    const remaining = self.output.len - self.bytes;
                    const limit = @min(multi.transfer_bytes, remaining);
                    if (transfer.failure != null or transfer.transferred > limit or (transfer.transferred == 0 and !transfer.eof)) {
                        return self.stopLane();
                    }
                    @memcpy(self.output[self.bytes..][0..transfer.transferred], response.data[0..transfer.transferred]);
                    self.bytes += transfer.transferred;
                    self.eof = transfer.eof;
                    if (self.eof or self.bytes == self.output.len) return self.closeRequest(req);
                    return self.readRequest(req);
                },
                .failure => return self.stopLane(),
                else => return self.stopLane(),
            },
            .close => switch (response.result) {
                .ok => {
                    self.phase = .done;
                    return .complete;
                },
                else => return self.stopLane(),
            },
            else => unreachable,
        }
    }
    pub fn abort(self: *Reader) Progress {
        return self.stopLane();
    }
};
