//! Typed fixed-record logging without allocation or formatting machinery.
//! One sink-specific loop serves all record schemas, keeping native code small.
const std = @import("std");

const Field = struct { name: [*]const u8, length: u16, offset: u16 };

fn schema(comptime T: type, comptime names: anytype) [names.len]Field {
    if (@typeInfo(T).@"struct".layout == .@"packed")
        @compileError("record fields require an unpacked struct");
    var fields: [names.len]Field = undefined;
    inline for (names, 0..) |name, index| {
        const field = std.meta.fieldIndex(T, name) orelse @compileError("unknown record field: " ++ name);
        if (@typeInfo(T).@"struct".field_attrs[field].@"comptime")
            @compileError("record fields require runtime storage: " ++ name);
        // SAFETY: @TypeOf inspects the field without evaluating undefined data.
        if (@TypeOf(@field(@as(T, undefined), name)) != u32)
            @compileError("record fields must be u32: " ++ name);
        if (@alignOf(T) < @alignOf(u32) or @offsetOf(T, name) % @alignOf(u32) != 0)
            @compileError("record fields require natural u32 alignment");
        if (name.len > std.math.maxInt(u16) or @offsetOf(T, name) > std.math.maxInt(u16))
            @compileError("record schema exceeds the bounded descriptor format");
        fields[index] = .{ .name = name.ptr, .length = @intCast(name.len), .offset = @intCast(@offsetOf(T, name)) };
    }
    return fields;
}

pub fn Writer(comptime Sink: type) type {
    return struct {
        const Self = @This();
        sink: Sink,

        /// Only the typed entry point constructs the private descriptor table.
        pub fn record(self: *Self, marker: []const u8, hart: ?u32, comptime names: anytype, value: anytype) void {
            const T = @TypeOf(value.*);
            const alignment = @typeInfo(@TypeOf(value)).pointer.attrs.@"align" orelse @alignOf(T);
            if (alignment < @alignOf(u32))
                @compileError("record pointer requires natural u32 alignment");
            const fields = comptime schema(T, names);
            self.emit(marker, hart, &fields, @ptrCast(value));
        }

        noinline fn emit(self: *Self, marker: []const u8, hart: ?u32, fields: []const Field, bytes: [*]const u8) void {
            self.sink.write(marker);
            if (hart) |number| {
                self.sink.write(" hart=");
                self.hex(number);
            }
            for (fields) |field| {
                self.sink.write(" ");
                self.sink.write(field.name[0..field.length]);
                self.sink.write("=");
                // SAFETY: schema checked the type and @offsetOf supplies the
                // real field location, including Zig's automatic layout.
                const word: *const u32 = @ptrCast(@alignCast(bytes + field.offset));
                self.hex(word.*);
            }
            self.sink.write("\n");
        }

        fn hex(self: *Self, value: u32) void {
            const digits = "0123456789abcdef";
            var buffer: [8]u8 = undefined;
            for (&buffer, 0..) |*byte, index| byte.* = digits[(value >> @as(u5, @intCast((7 - index) * 4))) & 15];
            self.sink.write(&buffer);
        }
    };
}

const Buffer = struct {
    bytes: [512]u8 = @splat(0),
    length: usize = 0,
    fn write(self: *Buffer, value: []const u8) void {
        @memcpy(self.bytes[self.length..][0..value.len], value);
        self.length += value.len;
    }
};

test "records retain explicit field order full u32 values and optional hart" {
    var output = Buffer{};
    var writer = Writer(*Buffer){ .sink = &output };
    const Record = struct { status: u32, first: u32, last: u32 };
    const value = Record{ .status = 1, .first = 0x80000000, .last = std.math.maxInt(u32) };
    writer.record("NIHOS_TEST", 1, .{ "last", "status", "first" }, &value);
    try std.testing.expectEqualStrings("NIHOS_TEST hart=00000001 last=ffffffff status=00000001 first=80000000\n", output.bytes[0..output.length]);
    output.length = 0;
    writer.record("NIHOS_TEST", null, .{"status"}, &value);
    try std.testing.expectEqualStrings("NIHOS_TEST status=00000001\n", output.bytes[0..output.length]);
}

test "schema follows actual layout instead of treating a struct as a u32 array" {
    const Mixed = struct { ignored: u8, data: u32, unused: u64, other: u32 };
    var output = Buffer{};
    var writer = Writer(*Buffer){ .sink = &output };
    const value = Mixed{ .ignored = 0xee, .data = 0x10203040, .unused = 0x1111111122222222, .other = 7 };
    writer.record("MIXED", null, .{ "other", "data" }, &value);
    try std.testing.expectEqualStrings("MIXED other=00000007 data=10203040\n", output.bytes[0..output.length]);
}
