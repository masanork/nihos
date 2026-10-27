const std = @import("std");
const api = @import("vfs.zig");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
const read = api.Rights{ .read = true };
const write = api.Rights{ .write = true };
const both = api.Rights{ .read = true, .write = true };
const writable = api.Capabilities{ .write_at = true, .sync_file = true, .sync_volume = true };
const Core = api.Vfs(Fake, 2, 8);

// Sparse, existing-file backend: high offsets require no large RAM allocation.
// ASCII case and a FAT-style short alias resolve to one stable identity.
const Fake = struct {
    bytes: [64]u8 = @splat(0),
    file_size: u64 = 8,
    lookups: usize = 0,
    opens: usize = 0,
    closes: usize = 0,
    reads: usize = 0,
    writes: usize = 0,
    syncs: usize = 0,
    volume_syncs: usize = 0,
    last_offset: u64 = 0,
    partial: ?usize = null,
    failure: ?api.Failure = null,
    fail_open: bool = false,
    fail_close: bool = false,
    fail_sync: bool = false,
    bad_count: bool = false,
    bad_eof: bool = false,

    pub fn lookupBeneath(self: *Fake, root: u64, path: []const u8) api.Error!u64 {
        self.lookups += 1;
        if (root != 42) return error.PermissionDenied;
        if (std.ascii.eqlIgnoreCase(path, "memo.txt") or std.ascii.eqlIgnoreCase(path, "MEMO~1.TXT")) return 7;
        if (std.mem.eql(u8, path, "other.txt")) return 8;
        if (std.mem.eql(u8, path, "教材/漢字𠮷.txt")) return 9;
        return error.NotFound;
    }

    pub fn open(self: *Fake, identity: u64, rights: api.Rights) api.Error!u64 {
        _ = rights;
        self.opens += 1;
        if (self.fail_open) return error.IoError;
        return identity;
    }

    pub fn close(self: *Fake, token: u64) api.Error!void {
        _ = token;
        self.closes += 1;
        if (self.fail_close) return error.IoError;
    }

    pub fn readAt(self: *Fake, token: u64, offset: u64, buffer: []u8) api.Transfer {
        _ = token;
        self.reads += 1;
        self.last_offset = offset;
        const available = self.file_size - @min(offset, self.file_size);
        const count: usize = @intCast(@min(@min(available, buffer.len), self.partial orelse buffer.len));
        for (buffer[0..count], 0..) |*byte, index| {
            const position = offset + index;
            byte.* = if (position < self.bytes.len) self.bytes[@intCast(position)] else @truncate(position);
        }
        return .{
            .transferred = if (self.bad_count) buffer.len + 1 else count,
            .eof = available <= count,
            .failure = self.failure,
        };
    }

    pub fn writeAt(self: *Fake, token: u64, offset: u64, buffer: []const u8) api.Transfer {
        _ = token;
        self.writes += 1;
        self.last_offset = offset;
        const count = @min(buffer.len, self.partial orelse buffer.len);
        for (buffer[0..count], 0..) |byte, index| {
            const position = offset + index;
            if (position < self.bytes.len) self.bytes[@intCast(position)] = byte;
        }
        self.file_size = @max(self.file_size, offset + count);
        return .{ .transferred = if (self.bad_count) buffer.len + 1 else count, .eof = self.bad_eof, .failure = self.failure };
    }

    pub fn syncFile(self: *Fake, token: u64) api.Error!void {
        _ = token;
        self.syncs += 1;
        if (self.fail_sync) return error.IoError;
    }

    pub fn syncVolume(self: *Fake, root: u64) api.Error!void {
        _ = root;
        self.volume_syncs += 1;
        if (self.fail_sync) return error.IoError;
    }
};

test "mount policy restricts a writable backend before any backend call" {
    var fake = Fake{};
    var core = Core{};
    const mount = try core.mount(&fake, 42, writable, .{});
    try expectError(error.ReadOnly, core.grantRoot(mount, 1, both));
    const root = try core.grantRoot(mount, 1, read);
    const file = try core.openAt(1, root, "memo.txt", read);
    try expectError(error.PermissionDenied, core.writeAt(1, file, 0, "changed"));
    try equal(@as(usize, 0), fake.writes);
    try equal(@as(usize, 1), fake.opens);
    try expect(!(try core.queryMount(mount)).policy.writable);
    try core.close(1, file);
    try core.close(1, root);
    try core.unmount(mount);
    try equal(@as(usize, 0), fake.volume_syncs);
}

test "principal and root rights cannot be amplified by a file request" {
    var fake = Fake{};
    var core = Core{};
    const mount = try core.mount(&fake, 42, writable, .{ .writable = true });
    const root = try core.grantRoot(mount, 1, read);
    try expectError(error.PermissionDenied, core.openAt(2, root, "memo.txt", read));
    try expectError(error.PermissionDenied, core.openAt(1, root, "memo.txt", both));
    const file = try core.openAt(1, root, "memo.txt", read);
    var buffer: [8]u8 = @splat(0);
    try expectError(error.PermissionDenied, core.readAt(2, file, 0, &buffer));
    try expectError(error.PermissionDenied, core.close(2, file));
    try equal(@as(usize, 0), fake.reads);
    try core.close(1, file);
    try expectError(error.StaleHandle, core.readAt(1, file, 0, &buffer));
}

test "rooted UTF-8 paths reject traversal and backend drive syntax before lookup" {
    var fake = Fake{};
    var core = Core{};
    const mount = try core.mount(&fake, 42, .{ .max_path_bytes = 40 }, .{});
    const root = try core.grantRoot(mount, 1, read);
    const bad = [_][]const u8{ "", "/memo.txt", "../memo.txt", "x/../../memo.txt", "./memo.txt", "x//memo.txt", "x/", "0:memo.txt", "x\\memo.txt", "x\x00y", "\xff.txt" };
    for (bad) |path| try expectError(error.InvalidName, core.openAt(1, root, path, read));
    const long_path: [41]u8 = @splat('a');
    try expectError(error.TooLarge, core.openAt(1, root, &long_path, read));
    try equal(@as(usize, 0), fake.lookups);
    _ = try core.openAt(1, root, "教材/漢字𠮷.txt", read);
    try equal(@as(usize, 1), fake.opens);
}

test "aliases share writer exclusion across principals and roots" {
    var fake = Fake{};
    var core = Core{};
    const mount = try core.mount(&fake, 42, writable, .{ .writable = true });
    const root_a = try core.grantRoot(mount, 1, both);
    const root_b = try core.grantRoot(mount, 2, both);
    const reader = try core.openAt(1, root_a, "memo.txt", read);
    const other_reader = try core.openAt(2, root_b, "MEMO~1.TXT", read);
    try expectError(error.Busy, core.openAt(2, root_b, "MEMO.TXT", write));
    try equal(@as(usize, 2), fake.opens);
    try core.close(1, reader);
    try core.close(2, other_reader);
    const writer = try core.openAt(1, root_a, "MEMO~1.TXT", both);
    try expectError(error.Busy, core.openAt(2, root_b, "memo.txt", read));
    _ = try core.openAt(2, root_b, "other.txt", write);
    try core.close(1, writer);
}

test "offsets cross signed 32-bit and 4 GiB boundaries without narrowing" {
    var fake = Fake{ .file_size = (@as(u64, 1) << 32) + 16 };
    var core = Core{};
    const mount = try core.mount(&fake, 42, writable, .{ .writable = true });
    const root = try core.grantRoot(mount, 1, both);
    const file = try core.openAt(1, root, "memo.txt", both);
    var buffer: [8]u8 = @splat(0);
    for ([_]u64{ 0x7fff_fffc, 0xffff_fffc, 0x1_0000_0000 }) |offset| {
        const result = try core.readAt(1, file, offset, &buffer);
        try equal(@as(usize, 8), result.transferred);
        try equal(offset, fake.last_offset);
        try equal(@as(u8, @truncate(offset + 7)), buffer[7]);
        _ = try core.writeAt(1, file, offset, &buffer);
        try equal(offset, fake.last_offset);
    }
    const calls = fake.reads + fake.writes;
    try expectError(error.TooLarge, core.readAt(1, file, std.math.maxInt(u64) - 3, &buffer));
    try expectError(error.TooLarge, core.writeAt(1, file, std.math.maxInt(u64), "x"));
    try equal(calls, fake.reads + fake.writes);
}

test "backend file and transfer limits fail before sparse backend access" {
    var fake = Fake{};
    var core = Core{};
    var caps = writable;
    caps.max_file_size = 0xffff_ffff;
    caps.max_transfer = 8;
    const mount = try core.mount(&fake, 42, caps, .{ .writable = true });
    const root = try core.grantRoot(mount, 1, both);
    const file = try core.openAt(1, root, "memo.txt", both);
    _ = try core.writeAt(1, file, 0xffff_fffe, "x");
    try equal(@as(u64, 0xffff_fffe), fake.last_offset);
    try expectError(error.TooLarge, core.writeAt(1, file, 0xffff_ffff, "x"));
    try expectError(error.TooLarge, core.writeAt(1, file, 0, "123456789"));
    try equal(@as(usize, 1), fake.writes);
}

test "short reads preserve EOF distinction and do not zero unrelated buffer bytes" {
    var fake = Fake{ .file_size = 3 };
    @memcpy(fake.bytes[0..3], "abc");
    var core = Core{};
    const mount = try core.mount(&fake, 42, .{}, .{});
    const root = try core.grantRoot(mount, 1, read);
    const file = try core.openAt(1, root, "memo.txt", read);
    var buffer: [8]u8 = @splat(0xaa);
    const result = try core.readAt(1, file, 0, &buffer);
    try equal(@as(usize, 3), result.transferred);
    try expect(result.eof);
    try std.testing.expectEqualStrings("abc", buffer[0..3]);
    try equal(@as(u8, 0xaa), buffer[3]); // SQLite zero-fills in its own adapter.
    fake.partial = 1;
    const partial = try core.readAt(1, file, 0, &buffer);
    try equal(@as(usize, 1), partial.transferred);
    try expect(!partial.eof);
    fake.partial = null;
    const eof = try core.readAt(1, file, 9, &buffer);
    try equal(@as(usize, 0), eof.transferred);
    try expect(eof.eof);
}

test "partial writes retain actual bytes and no-space status" {
    var fake = Fake{ .partial = 3, .failure = .no_space };
    var core = Core{};
    const mount = try core.mount(&fake, 42, writable, .{ .writable = true });
    const root = try core.grantRoot(mount, 1, both);
    const file = try core.openAt(1, root, "memo.txt", both);
    const result = try core.writeAt(1, file, 0, "abcdef");
    try equal(@as(usize, 3), result.transferred);
    try equal(api.Failure.no_space, result.failure.?);
    try std.testing.expectEqualStrings("abc", fake.bytes[0..3]);
    try equal(api.State.mounted, (try core.queryMount(mount)).state);
}

test "write timeout reports unknown outcome and blocks subsequent I/O" {
    var fake = Fake{ .partial = 2, .failure = .timed_out };
    var core = Core{};
    const mount = try core.mount(&fake, 42, writable, .{ .writable = true });
    const root = try core.grantRoot(mount, 1, both);
    const file = try core.openAt(1, root, "memo.txt", both);
    const result = try core.writeAt(1, file, 0, "abcd");
    try equal(@as(usize, 2), result.transferred);
    try equal(api.Failure.outcome_unknown, result.failure.?);
    try expectError(error.RecoveryRequired, core.writeAt(1, file, 0, "retry"));
    try equal(@as(usize, 1), fake.writes);
}

test "removal and same-slot replacement reject old capabilities without backend calls" {
    var old = Fake{};
    var replacement = Fake{};
    var core = Core{};
    const mount = try core.mount(&old, 42, .{}, .{});
    const root = try core.grantRoot(mount, 1, read);
    const file = try core.openAt(1, root, "memo.txt", read);
    try core.markRemoved(mount);
    var buffer: [8]u8 = @splat(0);
    try expectError(error.StaleHandle, core.readAt(1, file, 0, &buffer));
    try expectError(error.StaleHandle, core.openAt(1, root, "memo.txt", read));
    try core.detachQuiescent(mount);
    const fresh_mount = try core.mount(&replacement, 42, .{}, .{});
    try equal(mount.slot, fresh_mount.slot);
    try expect(mount.generation != fresh_mount.generation);
    const fresh_root = try core.grantRoot(fresh_mount, 1, read);
    const fresh_file = try core.openAt(1, fresh_root, "memo.txt", read);
    try expectError(error.StaleHandle, core.readAt(1, file, 0, &buffer));
    try expectError(error.StaleHandle, core.close(1, root));
    try expectError(error.StaleHandle, core.detachQuiescent(mount));
    _ = try core.readAt(1, fresh_file, 0, &buffer);
    try equal(@as(usize, 0), old.reads + old.closes);
    try equal(@as(usize, 1), replacement.reads);
}

test "a removed transfer preserves its partial length then rejects new requests" {
    var fake = Fake{ .partial = 2, .failure = .removed };
    var core = Core{};
    const mount = try core.mount(&fake, 42, .{}, .{});
    const root = try core.grantRoot(mount, 1, read);
    const file = try core.openAt(1, root, "memo.txt", read);
    var buffer: [8]u8 = @splat(0);
    const result = try core.readAt(1, file, 0, &buffer);
    try equal(@as(usize, 2), result.transferred);
    try equal(api.Failure.removed, result.failure.?);
    try expectError(error.StaleHandle, core.readAt(1, file, 0, &buffer));
    try core.close(1, file);
    try equal(@as(usize, 0), fake.closes);
}

test "handle exhaustion and failed open never consume an extra slot" {
    var fake = Fake{};
    var core = api.Vfs(Fake, 1, 2){};
    const mount = try core.mount(&fake, 42, .{}, .{});
    const root = try core.grantRoot(mount, 1, read);
    fake.fail_open = true;
    try expectError(error.IoError, core.openAt(1, root, "memo.txt", read));
    fake.fail_open = false;
    const file = try core.openAt(1, root, "memo.txt", read);
    try expectError(error.NoHandles, core.openAt(1, root, "other.txt", read));
    try equal(@as(usize, 2), fake.lookups);
    try equal(@as(usize, 2), fake.opens);
    try core.close(1, file);
    const next = try core.openAt(1, root, "other.txt", read);
    try equal(file.slot, next.slot);
    try expect(file.generation != next.generation);
    try expectError(error.StaleHandle, core.close(1, file));
    try core.close(1, next);
}

test "sync capability is independent of write capability" {
    var fake = Fake{};
    var core = Core{};
    const mount = try core.mount(&fake, 42, .{ .write_at = true }, .{ .writable = true });
    const root = try core.grantRoot(mount, 1, both);
    const file = try core.openAt(1, root, "memo.txt", both);
    try expectError(error.Unsupported, core.syncFile(1, file));
    try expectError(error.Busy, core.unmount(mount));
    try core.close(1, file);
    try core.close(1, root);
    try expectError(error.Unsupported, core.unmount(mount));
    try equal(api.State.mounted, (try core.queryMount(mount)).state);
    try equal(@as(usize, 0), fake.syncs + fake.volume_syncs);
}

test "normal writable unmount flushes only after all handles are closed" {
    var fake = Fake{};
    var core = Core{};
    const mount = try core.mount(&fake, 42, writable, .{ .writable = true });
    const root = try core.grantRoot(mount, 1, both);
    const file = try core.openAt(1, root, "memo.txt", both);
    _ = try core.writeAt(1, file, 0, "saved");
    try core.syncFile(1, file);
    try expectError(error.Busy, core.unmount(mount));
    try equal(@as(usize, 0), fake.volume_syncs);
    try core.close(1, file);
    try core.close(1, root);
    try core.unmount(mount);
    try equal(@as(usize, 1), fake.syncs);
    try equal(@as(usize, 1), fake.volume_syncs);
    try expectError(error.StaleHandle, core.queryMount(mount));
}

test "file and volume sync failure cannot be reported as clean completion" {
    var fake = Fake{ .fail_sync = true };
    var core = Core{};
    var mount = try core.mount(&fake, 42, writable, .{ .writable = true });
    const root = try core.grantRoot(mount, 1, both);
    const file = try core.openAt(1, root, "memo.txt", both);
    try expectError(error.IoError, core.syncFile(1, file));
    try equal(api.State.faulted, (try core.queryMount(mount)).state);
    try expectError(error.RecoveryRequired, core.unmount(mount));
    try core.detachQuiescent(mount);
    mount = try core.mount(&fake, 42, writable, .{ .writable = true });
    try expectError(error.IoError, core.unmount(mount));
    try expectError(error.RecoveryRequired, core.unmount(mount));
    try equal(@as(usize, 1), fake.volume_syncs);
}

test "close failure revokes the file token and faults its mount" {
    var fake = Fake{ .fail_close = true };
    var core = Core{};
    const mount = try core.mount(&fake, 42, .{}, .{});
    const root = try core.grantRoot(mount, 1, read);
    const file = try core.openAt(1, root, "memo.txt", read);
    try expectError(error.IoError, core.close(1, file));
    try expectError(error.StaleHandle, core.close(1, file));
    try equal(@as(usize, 1), fake.closes);
    try equal(api.State.faulted, (try core.queryMount(mount)).state);
}

test "malformed backend transfer lengths and write EOF fault the mount" {
    var fake = Fake{ .bad_count = true };
    var core = Core{};
    var mount = try core.mount(&fake, 42, writable, .{ .writable = true });
    var root = try core.grantRoot(mount, 1, both);
    var file = try core.openAt(1, root, "memo.txt", both);
    var buffer: [8]u8 = @splat(0);
    try expectError(error.BackendContract, core.readAt(1, file, 0, &buffer));
    try expectError(error.RecoveryRequired, core.writeAt(1, file, 0, "x"));
    try core.detachQuiescent(mount);
    fake.bad_count = false;
    fake.bad_eof = true;
    mount = try core.mount(&fake, 42, writable, .{ .writable = true });
    root = try core.grantRoot(mount, 1, both);
    file = try core.openAt(1, root, "memo.txt", both);
    try expectError(error.BackendContract, core.writeAt(1, file, 0, "x"));
}

test "duplicate backend mounts and invalid profiles fail closed" {
    var fake = Fake{};
    var core = Core{};
    try expectError(error.Unsupported, core.mount(&fake, 42, .{}, .{ .writable = true }));
    try expectError(error.TooLarge, core.mount(&fake, 42, .{ .max_transfer = 0 }, .{}));
    try expectError(error.TooLarge, core.mount(&fake, 42, .{ .max_path_bytes = 512 }, .{}));
    try expectError(error.TooLarge, core.mount(&fake, 42, .{ .max_transfer = 4097 }, .{}));
    const mount = try core.mount(&fake, 42, .{}, .{});
    try expectError(error.Busy, core.mount(&fake, 42, .{}, .{}));
    try core.markRemoved(mount);
    try expectError(error.Busy, core.mount(&fake, 42, .{}, .{}));
    try core.detachQuiescent(mount);
    _ = try core.mount(&fake, 42, .{}, .{});
}

test "independent mount identities and policies do not share file locks" {
    var writable_fs = Fake{};
    var read_only_fs = Fake{};
    var core = Core{};
    const write_mount = try core.mount(&writable_fs, 42, writable, .{ .writable = true });
    const read_mount = try core.mount(&read_only_fs, 42, .{}, .{});
    const write_root = try core.grantRoot(write_mount, 1, both);
    const read_root = try core.grantRoot(read_mount, 1, read);
    const writer = try core.openAt(1, write_root, "memo.txt", both);
    const reader = try core.openAt(1, read_root, "MEMO~1.TXT", read);
    try expectError(error.ReadOnly, core.grantRoot(read_mount, 1, write));
    _ = try core.writeAt(1, writer, 0, "hello");
    var buffer: [8]u8 = @splat(0);
    _ = try core.readAt(1, reader, 0, &buffer);
    try equal(@as(usize, 1), writable_fs.writes);
    try equal(@as(usize, 0), read_only_fs.writes);
    try equal(@as(usize, 1), read_only_fs.reads);
}

test "generation exhaustion retires slots instead of wrapping stale tokens" {
    var fake = Fake{};
    var core = api.Vfs(Fake, 1, 1){};
    const mount = try core.mount(&fake, 42, .{}, .{});
    core.handles[0].generation = std.math.maxInt(u64);
    const root = try core.grantRoot(mount, 1, read);
    try core.close(1, root);
    try expectError(error.NoHandles, core.grantRoot(mount, 1, read));
    try expectError(error.StaleHandle, core.close(1, root));
    core.mounts[0].generation = std.math.maxInt(u64);
    const last = api.Mount{ .slot = 0, .generation = std.math.maxInt(u64) };
    try core.unmount(last);
    try expectError(error.NoHandles, core.mount(&fake, 42, .{}, .{}));
}

test "development profile distinguishes open objects from data-file handles" {
    var fake = Fake{};
    var core = api.Vfs(Fake, api.standard_limits.mounts, api.standard_limits.open_objects){};
    const mount = try core.mount(&fake, 42, .{}, .{});
    const root = try core.grantRoot(mount, 1, read);
    var files: [api.standard_limits.file_handles]api.Handle = undefined;
    for (&files) |*file| file.* = try core.openAt(1, root, "memo.txt", read);
    try expectError(error.NoHandles, core.openAt(1, root, "memo.txt", read));
    try equal(@as(usize, 16), fake.opens);
    _ = try core.grantRoot(mount, 2, read); // Other object slots remain free.
    try core.close(1, files[0]);
    _ = try core.openAt(1, root, "memo.txt", read);
    try equal(@as(usize, 4096), api.standard_limits.io_bytes);
    try equal(@as(usize, 511), api.standard_limits.path_bytes);
}
