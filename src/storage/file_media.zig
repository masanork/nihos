//! Host image backend for the experimental publication model. Opens only an
//! existing fixed-size regular file; creation and directory sync belong to the
//! caller. File sync is not a physical-device power-loss qualification.
const std = @import("std");
const Io = std.Io;
pub const OpenError = Io.File.OpenError || Io.File.StatError || error{ WrongType, WrongSize };

pub fn Media(comptime byte_count: usize) type {
    if (byte_count == 0 or byte_count % 4096 != 0) @compileError("whole model pages required");
    return struct {
        const Self = @This();
        pub const capacity = byte_count;
        io: Io,
        file: Io.File,
        closed: bool = false,
        faulted: bool = false,
        writes: usize = 0,
        syncs: usize = 0,

        pub fn open(io: Io, dir: Io.Dir, path: []const u8) OpenError!Self {
            const file = try dir.openFile(io, path, .{
                .mode = .read_write,
                .lock = .exclusive,
                .lock_nonblocking = true,
                .follow_symlinks = false,
                .allow_ctty = false,
            });
            errdefer file.close(io);
            const info = try file.stat(io);
            if (info.kind != .file) return error.WrongType;
            if (info.size != capacity) return error.WrongSize;
            return .{ .io = io, .file = file };
        }

        pub fn close(self: *Self) void {
            if (self.closed) return;
            self.file.close(self.io);
            self.closed = true;
        }

        fn fail(self: *Self) error{Io} {
            self.faulted = true;
            return error.Io;
        }

        fn usable(self: *Self, offset: usize, length: usize) bool {
            return !self.closed and !self.faulted and offset <= capacity and length <= capacity - offset;
        }

        pub fn read(self: *Self, offset: usize, destination: []u8) error{Io}!void {
            if (!self.usable(offset, destination.len)) return self.fail();
            const n = self.file.readPositionalAll(self.io, destination, offset) catch return self.fail();
            if (n != destination.len) return self.fail();
        }

        pub fn write(self: *Self, offset: usize, data: []const u8) error{Io}!void {
            if (!self.usable(offset, data.len) or offset % 512 != 0 or data.len % 512 != 0) return self.fail();
            var position: usize = 0;
            while (position < data.len) {
                const n = self.file.writePositional(self.io, &.{data[position..]}, offset + position) catch return self.fail();
                if (n == 0 or n > data.len - position) return self.fail();
                position += n;
                self.writes += 1;
            }
        }

        pub fn sync(self: *Self) error{Io}!void {
            if (!self.usable(0, 0)) return self.fail();
            self.file.sync(self.io) catch return self.fail();
            self.syncs += 1;
        }
    };
}
