//! Bounded native touch reads; register reference: Espressif ST7123 1.0.2
//! and GT911 drivers. Bus/power ownership remains with the calling CPU0 owner.
const std = @import("std");
pub const Panel = enum { st7121, st7123, ili9881c };
pub const Error = error{ Identity, Geometry, Malformed, ControllerReset };
pub const Point = struct { contacts: u8, x: u16 = 0, y: u16 = 0 };
pub const Sample = union(enum) { unchanged, fresh: Point };
pub const Device = struct {
    panel: Panel,
    slots: u8,
    width: u16,
    height: u16,

    pub fn identify(bus: anytype, panel: Panel) !Device {
        if (panel == .ili9881c) {
            var identity: [4]u8 = @splat(0);
            try bus.transfer(0x5d, &.{ 0x40, 0x81 }, &identity);
            if (!std.mem.eql(u8, &identity, "911\x00")) return error.Identity;
            var size: [4]u8 = @splat(0);
            try bus.transfer(0x5d, &.{ 0x48, 0x80 }, &size);
            const width = le(size[0..2]);
            const height = le(size[2..4]);
            if (width != 720 or height != 1280) return error.Geometry;
            return .{ .panel = panel, .slots = 5, .width = width, .height = height };
        }
        var firmware: [1]u8 = .{0};
        try bus.transfer(0x55, &.{ 0, 0 }, &firmware);
        if (firmware[0] != (if (panel == .st7121) @as(u8, 1) else 3)) return error.Identity;
        var info: [5]u8 = @splat(0);
        try bus.transfer(0x55, &.{ 0, 5 }, &info);
        const width = be(info[0..2]);
        const height = be(info[2..4]);
        if (width != 720 or height != 1280) return error.Geometry;
        if (info[4] == 0 or info[4] > 10) return error.Malformed;
        return .{ .panel = panel, .slots = info[4], .width = width, .height = height };
    }
    pub fn sample(self: Device, bus: anytype) !Sample {
        if (self.panel == .ili9881c) return self.goodix(bus);
        var flags: [1]u8 = .{0};
        try bus.transfer(0x55, &.{ 0, 0x10 }, &flags);
        if (flags[0] & 0x80 != 0) return error.ControllerReset;
        // No new report must not synthesize a finger-release / PIN key press.
        if (flags[0] & 8 == 0) return .unchanged;
        var result = Point{ .contacts = 0 };
        // Contiguous report registers; nine whole records fit the 64-byte
        // bus limit. Read every advertised slot, including sparse late fingers.
        var first: usize = 0;
        while (first < self.slots) {
            var chunk: [63]u8 = @splat(0);
            const count: usize = @min(@as(usize, self.slots) - first, 9);
            const offset: u8 = @intCast(0x14 + first * 7);
            try bus.transfer(0x55, &.{ 0, offset }, chunk[0 .. count * 7]);
            for (0..count) |index| {
                const record = chunk[index * 7 ..][0..7];
                if (record[0] & 0x80 == 0) continue;
                if (record[0] & 0x40 != 0) return error.Malformed;
                const x = (@as(u16, record[0] & 0x3f) << 8) | record[1];
                const y = be(record[2..4]);
                if (x >= self.width or y >= self.height) return error.Geometry;
                if (result.contacts == 0) {
                    result.x = x;
                    result.y = y;
                }
                result.contacts += 1;
            }
            first += count;
        }
        return .{ .fresh = result };
    }
    fn goodix(self: Device, bus: anytype) !Sample {
        var flags: [1]u8 = .{0};
        try bus.transfer(0x5d, &.{ 0x4e, 0x81 }, &flags);
        if (flags[0] & 0x80 == 0) return .unchanged;
        if (flags[0] & 0x70 != 0 or flags[0] & 15 > 5) return error.Malformed;
        var result = Point{ .contacts = flags[0] & 15 };
        var records: [40]u8 = @splat(0);
        if (result.contacts > 0) {
            try bus.transfer(0x5d, &.{ 0x4f, 0x81 }, records[0 .. @as(usize, result.contacts) * 8]);
            for (0..result.contacts) |index| {
                const record = records[index * 8 ..][0..8];
                const x = le(record[1..3]);
                const y = le(record[3..5]);
                if (x >= self.width or y >= self.height) return error.Geometry;
                if (index == 0) {
                    result.x = x;
                    result.y = y;
                }
            }
        }
        try bus.transfer(0x5d, &.{ 0x4e, 0x81, 0 }, &.{});
        return .{ .fresh = result };
    }
};
fn be(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) << 8 | bytes[1];
}
fn le(bytes: []const u8) u16 {
    return @as(u16, bytes[1]) << 8 | bytes[0];
}

const Model = struct {
    firmware: u8 = 1,
    slots: u8 = 10,
    flags: u8 = 8,
    records: [70]u8 = @splat(0),
    count: usize = 0,
    clear: u32 = 0,
    width: u16 = 720,
    report_reads: usize = 0,
    report_bytes: usize = 0,
    max_report_read: usize = 0,
    fail_report_read: usize = 0,
    pub fn transfer(self: *Model, address: u8, write: []const u8, output: []u8) !void {
        if (write.len == 3) {
            try std.testing.expectEqualSlices(u8, &.{ 0x4e, 0x81, 0 }, write);
            self.clear += 1;
            return;
        }
        self.count += 1;
        if (address == 0x55) {
            const reg = be(write);
            switch (reg) {
                0 => output[0] = self.firmware,
                5 => @memcpy(output, &[_]u8{ @truncate(self.width >> 8), @truncate(self.width), 5, 0, self.slots }),
                0x10 => output[0] = self.flags,
                else => {
                    if (reg < 0x14 or reg > 0x53 or (reg - 0x14) % 7 != 0 or output.len == 0 or output.len > 64 or output.len % 7 != 0 or reg - 0x14 + output.len > self.records.len) return error.Register;
                    self.report_reads += 1;
                    if (self.report_reads == self.fail_report_read) return error.Nack;
                    self.report_bytes += output.len;
                    self.max_report_read = @max(self.max_report_read, output.len);
                    @memcpy(output, self.records[reg - 0x14 ..][0..output.len]);
                },
            }
        } else if (address == 0x5d) {
            const reg = le(write);
            switch (reg) {
                0x8140 => @memcpy(output, "911\x00"),
                0x8048 => @memcpy(output, &[_]u8{ 0xd0, 2, 0, 5 }),
                0x814e => output[0] = self.flags,
                0x814f => @memcpy(output, self.records[0..output.len]),
                else => return error.Register,
            }
        } else return error.Address;
    }
};
test "Sitronix identity, ten-slot reads, explicit release and absent report" {
    var model = Model{};
    const device = try Device.identify(&model, .st7121);
    @memcpy(model.records[0..7], &[_]u8{ 0x82, 0xcf, 4, 0xff, 1, 1, 0 });
    const point = (try device.sample(&model)).fresh;
    try std.testing.expectEqualDeep(Point{ .contacts = 1, .x = 719, .y = 1279 }, point);
    try std.testing.expectEqual(@as(usize, 5), model.count);
    try std.testing.expectEqual(@as(usize, 70), model.report_bytes);
    try std.testing.expectEqual(@as(usize, 63), model.max_report_read);
    model.records = @splat(0);
    try std.testing.expectEqual(@as(u8, 0), (try device.sample(&model)).fresh.contacts);
    model.flags = 0;
    try std.testing.expect(try device.sample(&model) == .unchanged);
    model.flags = 0x88;
    try std.testing.expectError(error.ControllerReset, device.sample(&model));
}

test "Sitronix burst boundaries preserve sparse tenth contact and multiple-contact rejection" {
    var model = Model{};
    const device = try Device.identify(&model, .st7121);
    model.records[0] = 0x80;
    @memcpy(model.records[63..70], &[_]u8{ 0x82, 0xcf, 4, 0xff, 1, 1, 0 });
    try std.testing.expectEqual(@as(u8, 2), (try device.sample(&model)).fresh.contacts);
    try std.testing.expectEqual(@as(usize, 2), model.report_reads);
    model.records[0] = 0;
    try std.testing.expectEqualDeep(Point{ .contacts = 1, .x = 719, .y = 1279 }, (try device.sample(&model)).fresh);
    model.records[63] = 0x83;
    try std.testing.expectError(error.Geometry, device.sample(&model));
}

test "Sitronix short report batches stay bounded and a failed second burst cannot publish a partial sample" {
    for ([_]u8{ 1, 9, 10 }) |slots| {
        var model = Model{ .slots = slots, .firmware = 3 };
        const device = try Device.identify(&model, .st7123);
        try std.testing.expectEqual(@as(u8, 0), (try device.sample(&model)).fresh.contacts);
        try std.testing.expectEqual(@as(usize, slots) * 7, model.report_bytes);
        try std.testing.expect(model.max_report_read <= 63);
        try std.testing.expectEqual(if (slots == 10) @as(usize, 2) else 1, model.report_reads);
    }
    var model = Model{ .fail_report_read = 2 };
    const device = try Device.identify(&model, .st7121);
    model.records[0] = 0x80;
    try std.testing.expectError(error.Nack, device.sample(&model));
}
test "touch malformed geometry or multiple fingers cannot become a single key press" {
    var model = Model{};
    const device = try Device.identify(&model, .st7121);
    model.records[0] = 0x80;
    model.records[7] = 0x80;
    try std.testing.expectEqual(@as(u8, 2), (try device.sample(&model)).fresh.contacts);
    model.records[0] = 0x83;
    try std.testing.expectError(error.Geometry, device.sample(&model));
    model.records[0] = 0xc0;
    try std.testing.expectError(error.Malformed, device.sample(&model));
    model.slots = 11;
    try std.testing.expectError(error.Malformed, Device.identify(&model, .st7121));
    model.firmware = 3;
    try std.testing.expectError(error.Identity, Device.identify(&model, .st7121));
    model.firmware = 1;
    model.width = 1280;
    try std.testing.expectError(error.Geometry, Device.identify(&model, .st7121));
}
test "Goodix report acknowledges only fresh frames and keeps explicit zero-contact release" {
    var model = Model{ .flags = 0 };
    const device = try Device.identify(&model, .ili9881c);
    try std.testing.expect(try device.sample(&model) == .unchanged);
    try std.testing.expectEqual(@as(u32, 0), model.clear);
    model.flags = 0x81;
    @memcpy(model.records[0..8], &[_]u8{ 0, 0xcf, 2, 0xff, 4, 1, 0, 0 });
    try std.testing.expectEqualDeep(Point{ .contacts = 1, .x = 719, .y = 1279 }, (try device.sample(&model)).fresh);
    model.flags = 0x80;
    try std.testing.expectEqual(@as(u8, 0), (try device.sample(&model)).fresh.contacts);
    try std.testing.expectEqual(@as(u32, 2), model.clear);
    model.flags = 0x86;
    try std.testing.expectError(error.Malformed, device.sample(&model));
}
