//! Synchronous read-only Backend over the pinned C FatFs session.
//! Trusted storage owner only; epoch/workspace/controller lifetime is external.
pub const vfs = @import("vfs.zig");
pub const Session = opaque {};
pub extern fn nih_fatfs_backend_lookup(*Session, u64, u64, [*]const u8, u32, *u64) c_int;
pub extern fn nih_fatfs_backend_open(*Session, u64, u64, *u64) c_int;
pub extern fn nih_fatfs_backend_read(*Session, u64, u64, u64, [*]u8, u32, *u32, *u32) c_int;
pub extern fn nih_fatfs_backend_close(*Session, u64, u64) c_int;

fn checked(status: c_int) vfs.Error!void {
    return switch (status) {
        0 => {},
        1 => error.NotFound,
        2 => error.InvalidName,
        3 => error.Corrupt,
        4 => error.IoError,
        5 => error.TooLarge,
        6 => error.StaleHandle,
        7 => error.Busy,
        8 => error.ReadOnly,
        9 => error.NoHandles,
        10 => error.RecoveryRequired,
        else => error.BackendContract,
    };
}
pub const Backend = struct {
    session: *Session,
    epoch: u64,
    pub fn lookupBeneath(self: *@This(), root: u64, path: []const u8) vfs.Error!u64 {
        if (root != 1) return error.PermissionDenied;
        if (path.len == 0 or path.len > vfs.standard_limits.path_bytes) return error.TooLarge;
        var identity: u64 = 0;
        try checked(nih_fatfs_backend_lookup(self.session, self.epoch, root, path.ptr, @intCast(path.len), &identity));
        return identity;
    }
    pub fn open(self: *@This(), identity: u64, rights: vfs.Rights) vfs.Error!u64 {
        if (rights.write) return error.ReadOnly;
        if (!rights.read) return error.PermissionDenied;
        var token: u64 = 0;
        try checked(nih_fatfs_backend_open(self.session, self.epoch, identity, &token));
        return token;
    }
    pub fn close(self: *@This(), token: u64) vfs.Error!void {
        try checked(nih_fatfs_backend_close(self.session, self.epoch, token));
    }
    pub fn readAt(self: *@This(), token: u64, offset: u64, buffer: []u8) vfs.Transfer {
        if (buffer.len > vfs.standard_limits.io_bytes) return .{ .failure = .io_error };
        var count: u32 = 0;
        var eof: u32 = 0;
        const status = nih_fatfs_backend_read(self.session, self.epoch, token, offset, buffer.ptr, @intCast(buffer.len), &count, &eof);
        if (status != 0) return .{ .failure = if (status == 3) .corrupt else if (status == 10) .removed else .io_error };
        return .{ .transferred = count, .eof = eof == 1 };
    }
    pub fn writeAt(_: *@This(), _: u64, _: u64, _: []const u8) vfs.Transfer {
        return .{ .failure = .io_error };
    }
    pub fn syncFile(_: *@This(), _: u64) vfs.Error!void {
        return error.ReadOnly;
    }
    pub fn syncVolume(_: *@This(), _: u64) vfs.Error!void {
        return error.ReadOnly;
    }
};
