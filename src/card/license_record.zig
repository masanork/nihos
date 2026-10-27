//! NPA read records. Borrowed slices never outlive the private card workspace.
const std = @import("std");
const base = @import("license.zig");
const jis = @import("jis0208.zig");
pub const Error = base.Error;
pub const History = struct { tag: u8, date: [8]u8, text: []const u8, authority: []const u8 };
pub const TagEncoding = enum { none, literal, ff };
pub const Signature = struct { value: *const [256]u8, key_id: []const u8, encoding: TagEncoding = .literal };
pub const SignedRecord = struct { data: []const u8, signature: Signature };
pub const Verification = enum(u32) { not_checked, unknown_key, valid, invalid, malformed };
pub const ExtendedIterator = struct {
    bytes: []const u8,
    offset: usize = 0,
    encoding: TagEncoding = .none,
    pub fn next(self: *ExtendedIterator) Error!?base.Tlv {
        if (self.offset == self.bytes.len) return null;
        const rest = self.bytes[self.offset..];
        if (rest[0] == 0 or rest[0] == 255) {
            var padding = true;
            for (rest) |b| if (b != 0 and b != 255) {
                padding = false;
                break;
            };
            if (padding) {
                self.offset = self.bytes.len;
                return null;
            }
        }
        var tag: u16 = rest[0];
        self.offset += 1;
        if (tag == 1 or (tag == 255 and self.encoding != .literal)) {
            const encoding: @TypeOf(self.encoding) = if (tag == 1) .literal else .ff;
            if (self.encoding != .none and self.encoding != encoding) return error.Malformed;
            self.encoding = encoding;
            if (self.offset == self.bytes.len or self.bytes[self.offset] > 13) return error.Malformed;
            tag = 0x100 + @as(u16, self.bytes[self.offset]);
            self.offset += 1;
        } else if (tag < 0xc1 or tag > 0xff) return error.Malformed;
        if (self.offset == self.bytes.len) return error.Malformed;
        var length: usize = self.bytes[self.offset];
        self.offset += 1;
        if (length >= 128) {
            if (length != 0x82 or self.bytes.len - self.offset < 2) return error.Malformed;
            length = std.mem.readInt(u16, self.bytes[self.offset..][0..2], .big);
            self.offset += 2;
            if (length < 128) return error.Malformed;
        }
        if (length > self.bytes.len - self.offset) return error.Malformed;
        const value = self.bytes[self.offset..][0..length];
        self.offset += length;
        return .{ .tag = tag, .value = value };
    }
};
fn placement(comptime section: ?[]const u8) []const u8 {
    return section orelse if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text";
}
pub fn Parser(comptime section: ?[]const u8) type {
    return struct {
        pub noinline fn envelope(workspace: []const u8, is_myna: bool) linksection(placement(section)) Error!SignedRecord {
            if (workspace.len != 32768) return error.Malformed;
            const signed = try signature(if (is_myna) workspace[5845..6429] else workspace[4270..4848], is_myna);
            if (is_myna and (try myna(workspace[0..5845])).encoding != signed.encoding) return error.Malformed;
            return .{ .data = workspace[0..if (is_myna) @as(usize, 5845) else 2967], .signature = signed };
        }
        pub noinline fn history(raw: []const u8, records: []History) linksection(placement(section)) Error![]History {
            if (raw.len != 640 and raw.len != 256) return error.Malformed;
            const domicile = raw.len == 256;
            var iterator = base.Iterator{ .bytes = raw };
            var flag = false;
            var seen: u128 = 0;
            var count: usize = 0;
            var last: [9]u8 = @splat(0);
            while (try iterator.next()) |field| {
                const first: u16 = if (domicile) 0xaa else 0x50;
                if (field.tag < first or field.tag > (if (domicile) @as(u16, 0xaf) else 0x97)) return error.Malformed;
                const bit = @as(u128, 1) << @as(u7, @intCast(field.tag - first));
                if (seen & bit != 0) return error.Duplicate;
                seen |= bit;
                if (field.tag == first) {
                    if (count != 0 or field.value.len != 1 or field.value[0] != 0x11) return error.Malformed;
                    flag = true;
                    continue;
                }
                if (!flag or field.value.len < 25 or count == records.len) return error.Malformed;
                const group: usize = if (domicile) 0 else if (field.tag < 0x60) 0 else 1 + (field.tag - 0x60) / 8;
                const start: u8 = if (domicile) 0xab else if (group == 0) 0x51 else @intCast(0x60 + (group - 1) * 8);
                if ((last[group] == 0 and field.tag != start) or (last[group] != 0 and field.tag != @as(u16, last[group]) + 1)) return error.Malformed;
                const maximum: usize = if (!domicile and group == 0) 25 else if (!domicile and group == 1) 97 else if (!domicile and group == 2) 57 else 105;
                if (field.value.len > maximum or field.value.len % 2 != 1 or (!domicile and group == 0 and field.value.len != 25)) return error.Malformed;
                var date: [7]u8 = undefined;
                defer std.crypto.secureZero(u8, &date);
                for (0..7) |i| {
                    if (field.value[1 + i * 2] != 0x23 or field.value[2 + i * 2] < 0x30 or field.value[2 + i * 2] > 0x39) return error.Malformed;
                    date[i] = field.value[2 + i * 2];
                }
                var converted: [8]u8 = undefined;
                defer std.crypto.secureZero(u8, &converted);
                try base.Parser(section).date(&date, &converted);
                if (last[group] != 0) {
                    var previous: ?History = null;
                    for (records[0..count]) |r| if (r.tag == last[group]) {
                        previous = r;
                        break;
                    };
                    if (previous == null or std.mem.order(u8, &previous.?.date, &converted) == .gt) return error.Malformed;
                }
                records[count] = .{ .tag = @intCast(field.tag), .date = converted, .text = field.value[15 .. field.value.len - 10], .authority = field.value[field.value.len - 10 ..] };
                last[group] = @intCast(field.tag);
                count += 1;
            }
            return records[0..count];
        }
        pub noinline fn current(common: []const u8, changes: []const u8, output: []u8) linksection(placement(section)) Error!base.Info {
            const original = try base.Parser(section).fields(common);
            var storage: [32]History = undefined;
            defer std.crypto.secureZero(u8, std.mem.asBytes(&storage));
            const records = try history(changes, &storage);
            var unresolved = false;
            var name = original.name;
            var address = original.address;
            for (records) |r| {
                if (r.tag >= 0x90 and r.tag <= 0x97) unresolved = true;
                if (r.tag >= 0x60 and r.tag <= 0x67) name = r.text;
                if (r.tag >= 0x70 and r.tag <= 0x77) address = r.text;
            }
            if (output.len != base.text_bytes) return error.TooLarge;
            const D = jis.Decoder(if (section != null) ".flash.license.data" else null);
            const n = D.decode(name, output[0..216]) catch return error.Malformed;
            const a = D.decode(address, output[216..480]) catch return error.Malformed;
            try base.Parser(section).date(original.birth_date, output[480..488]);
            try base.Parser(section).date(original.expiration, output[488..496]);
            return .{ .name = n.text, .address = a.text, .birth_date = output[480..488], .expiration = output[488..496], .number = original.number, .missing = n.missing + a.missing, .history_unresolved = unresolved };
        }
        pub noinline fn signature(raw: []const u8, is_myna: bool) linksection(placement(section)) Error!Signature {
            if (!is_myna) return signatureWith(raw, false, .literal);
            var found: ?Signature = null;
            for ([_]TagEncoding{ .literal, .ff }) |encoding| {
                if (signatureWith(raw, true, encoding)) |value| {
                    if (found != null) return error.Malformed;
                    found = value;
                } else |_| {}
            }
            return found orelse error.Malformed;
        }
        noinline fn signatureWith(raw: []const u8, is_myna: bool, encoding: TagEncoding) linksection(placement(section)) Error!Signature {
            if (raw.len != (if (is_myna) @as(usize, 584) else 578)) return error.Malformed;
            var normal = base.Iterator{ .bytes = raw };
            var extended = ExtendedIterator{ .bytes = raw, .encoding = encoding };
            var seen: u8 = 0;
            var value: ?*const [256]u8 = null;
            var key: []const u8 = &.{};
            while (if (is_myna) try extended.next() else try normal.next()) |field| {
                const first: u16 = if (is_myna) 0x108 else 0xb1;
                if (field.tag < first or field.tag > first + 5) return error.Malformed;
                const index: u3 = @intCast(field.tag - first);
                const bit = @as(u8, 1) << index;
                if (seen & bit != 0) return error.Duplicate;
                seen |= bit;
                const limits = [_]usize{ 256, 16, 48, 80, 130, 32 };
                if (field.value.len > limits[index]) return error.Malformed;
                if (index == 0) {
                    if (field.value.len != 256) return error.Malformed;
                    value = field.value[0..256];
                }
                if (index == 5) key = field.value;
            }
            if (value == null or key.len == 0) return error.Missing;
            return .{ .value = value.?, .key_id = key, .encoding = encoding };
        }
        pub const Myna = struct { number: []const u8, expiration: [8]u8, portrait: []const u8, types: u16, fields: u32, encoding: TagEncoding };
        pub noinline fn myna(raw: []const u8) linksection(placement(section)) Error!Myna {
            var found: ?Myna = null;
            defer std.crypto.secureZero(u8, std.mem.asBytes(&found));
            for ([_]TagEncoding{ .literal, .ff }) |encoding| {
                if (mynaWith(raw, encoding)) |value| {
                    if (found != null) return error.Malformed;
                    found = value;
                } else |_| {}
            }
            return found orelse error.Malformed;
        }
        noinline fn mynaWith(raw: []const u8, encoding: TagEncoding) linksection(placement(section)) Error!Myna {
            if (raw.len != 5845) return error.Malformed;
            var iterator = ExtendedIterator{ .bytes = raw, .encoding = encoding };
            var seen: u128 = 0;
            var number: []const u8 = &.{};
            var expiry: []const u8 = &.{};
            var photo: []const u8 = &.{};
            var types: u16 = 0;
            while (try iterator.next()) |field| {
                if (field.tag < 0xc2 or field.tag > 0x107) return error.Malformed;
                const bit = @as(u128, 1) << @as(u7, @intCast(field.tag - 0xc2));
                if (seen & bit != 0) return error.Duplicate;
                seen |= bit;
                if (field.tag == 0xc5) expiry = field.value;
                if (field.tag == 0xe7) number = field.value;
                if (field.tag == 0xe8 and field.value.len != 0) return error.Malformed; // History certificate is not a licence.
                if (field.tag == 0x107) photo = field.value;
                if (field.tag >= 0xec and field.tag <= 0xfa) {
                    if (field.value.len != 1 or field.value[0] > 1) return error.Malformed;
                    if (field.value[0] == 1) types |= @as(u16, 1) << @as(u4, @intCast(field.tag - 0xec));
                }
                if (field.tag >= 0xfb and field.tag <= 0x106 and field.value.len != 0 and field.value.len != 7) return error.Malformed;
                const text = (field.tag >= 0xc6 and field.tag <= 0xc9) or (field.tag >= 0xcc and field.tag <= 0xd3) or (field.tag >= 0xd7 and field.tag <= 0xe6);
                if (text and (field.value.len > 80 or field.value.len % 2 != 0)) return error.Malformed;
            }
            if (number.len != 12 or expiry.len != 7 or photo.len < 16 or photo.len > 2000) return error.Missing;
            for (number) |b| if (b < '0' or b > '9') return error.Malformed;
            if (!std.mem.startsWith(u8, photo, &.{ 0xff, 0x4f }) and !std.mem.startsWith(u8, photo, &.{ 0, 0, 0, 12, 0x6a, 0x50, 0x20, 0x20, 13, 10, 0x87, 10 })) return error.Malformed;
            var converted: [8]u8 = undefined;
            defer std.crypto.secureZero(u8, &converted);
            try base.Parser(section).date(expiry, &converted);
            return .{ .number = number, .expiration = converted, .portrait = photo, .types = types, .fields = 7, .encoding = encoding };
        }
    };
}
