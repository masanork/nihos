//! Bounded JIS row/cell decoding. Unknown/external glyphs stay visibly marked.
const std = @import("std");
pub const Error = error{ Malformed, TooLarge };
pub const Decoded = struct { text: []const u8, missing: u32 };
pub fn Decoder(comptime section: ?[]const u8) type {
    return struct {
        const placement = section orelse (if (@import("builtin").os.tag == .macos) "__TEXT,__const" else ".rodata");
        const data: [17672]u8 align(4) linksection(placement) = @embedFile("jis0208.bin").*;
        pub noinline fn decode(input: []const u8, output: []u8) linksection(if (section != null) ".flash.photo" else if (@import("builtin").os.tag == .macos) "__TEXT,__text" else ".text") Error!Decoded {
            if (input.len > 160) return error.TooLarge;
            var at: usize = 0;
            var used: usize = 0;
            var missing: u32 = 0;
            while (at < input.len) {
                var code: u21 = 0;
                const first = input[at];
                if (first == 0x20) {
                    code = ' ';
                    at += 1;
                } else if (first >= 0xa1 and first <= 0xdf) {
                    code = 0xff61 + @as(u21, first - 0xa1);
                    at += 1;
                } else {
                    if (input.len - at < 2) return error.Malformed;
                    const second = input[at + 1];
                    at += 2;
                    if (first == 0xff and (second >= 0xf1 and second <= 0xf7 or second == 0xfa)) {
                        code = 0;
                    } else {
                        if (first < 0x21 or first > 0x7e or second < 0x21 or second > 0x7e) return error.Malformed;
                        const index = (@as(usize, first - 0x21) * 94 + second - 0x21) * 2;
                        const live: *const volatile [17672]u8 = &data;
                        code = @as(u16, live[index]) | @as(u16, live[index + 1]) << 8;
                    }
                    if (code == 0) {
                        code = 0x25a1;
                        missing += 1;
                    }
                }
                const length = std.unicode.utf8CodepointSequenceLength(code) catch return error.Malformed;
                if (length > output.len - used) return error.TooLarge;
                _ = std.unicode.utf8Encode(code, output[used..][0..length]) catch return error.Malformed;
                used += length;
            }
            return .{ .text = output[0..used], .missing = missing };
        }
    };
}
test "JIS standard row cells, external glyph markers and bounded output" {
    var output: [64]u8 = undefined;
    const D = Decoder(null);
    try std.testing.expectEqualStrings("山田　太郎", (try D.decode("\x3b\x33\x45\x44\x21\x21\x42\x40\x4f\x3a", &output)).text);
    try std.testing.expectEqual(@as(u32, 1), (try D.decode("\xff\xf1", &output)).missing);
    try std.testing.expectError(error.Malformed, D.decode("\x21", &output));
    try std.testing.expectError(error.TooLarge, D.decode("\x3b\x33", output[0..2]));
}
