//! LDO channel 2 (VO2), dedicated to the 1.8 V PSRAM/MPLL domain.
//! Register/calibration facts: ESP-IDF v5.4.4 ldo_ll.h and P4 eFuse/PMU.
//! A successful register readback does not measure the analog supply voltage.
const std = @import("std");

pub const control_offset = 0x1d0;
pub const analog_offset = 0x1d4;
pub const control_mask: u32 = (1 << 7) | (1 << 8) | (7 << 9) | (1 << 14);
pub const control_bits: u32 = (1 << 7) | (1 << 8);
pub const analog_mask: u32 = (7 << 23) | (1 << 26) | (15 << 28);

pub const Setting = struct { dref: u4, mul: u3, calibrated: bool };

pub fn setting(word2: u32, word3: u32) Setting {
    const dref: u4 = @truncate(word2 >> 28);
    const mul: u3 = @truncate(word3 >> 3);
    // Major/minor block version is nonzero. Both VO2 trim fields must exist.
    if (word2 & (31 << 8) != 0 and dref != 0 and mul != 0)
        return .{ .dref = dref, .mul = mul, .calibrated = true };
    // Nominal VO2 model: 0.8 V * (1 + 0.25 * 5) = 1.8 V.
    // This is the first exact match in the IDF nominal DREF/MUL search.
    return .{ .dref = 6, .mul = 5, .calibrated = false };
}

pub fn analogBits(selected: Setting) u32 {
    return (@as(u32, selected.dref) << 28) | (@as(u32, selected.mul) << 23) | (1 << 26);
}

/// Caller owns this domain before CPU1 release. No generic regulator API.
pub fn program(io: anytype, selected: Setting) bool {
    const previous = io.read(control_offset);
    // Select the reference path and software ownership before enabling a
    // cold domain. Preserve unrelated delay and current-limit settings.
    io.write(control_offset, (previous & ~control_mask) | (1 << 7) | (previous & (1 << 8)));
    io.write(analog_offset, (io.read(analog_offset) & ~analog_mask) | analogBits(selected));
    io.write(control_offset, (previous & ~control_mask) | control_bits);
    return io.read(control_offset) & control_mask == control_bits and
        io.read(analog_offset) & analog_mask == analogBits(selected);
}

test "VO2 uses complete versioned trims and otherwise the nominal 1.8 V setting" {
    const nominal = Setting{ .dref = 6, .mul = 5, .calibrated = false };
    for ([_][2]u32{ .{ 0, 0 }, .{ 9 << 28, 3 << 3 }, .{ 1 << 8, 3 << 3 }, .{ (1 << 8) | (9 << 28), 0 } }) |words| {
        try std.testing.expectEqualDeep(nominal, setting(words[0], words[1]));
    }
    const trimmed = Setting{ .dref = 9, .mul = 3, .calibrated = true };
    try std.testing.expectEqualDeep(trimmed, setting((1 << 8) | (9 << 28), 3 << 3));
    try std.testing.expectEqualDeep(trimmed, setting((1 << 11) | (9 << 28), 3 << 3));
}

test "VO2 programming preserves unrelated bits and rejects dropped writes" {
    const Model = struct {
        words: [2]u32 = .{ 0x8000_7001, 0x0800_0003 },
        drop: bool = false,
        pub fn read(self: *@This(), offset: usize) u32 {
            return self.words[(offset - control_offset) / 4];
        }
        pub fn write(self: *@This(), offset: usize, value: u32) void {
            if (!self.drop) self.words[(offset - control_offset) / 4] = value;
        }
    };
    var model = Model{};
    const before = model.words;
    const selected = setting(0, 0);
    try std.testing.expect(program(&model, selected));
    try std.testing.expectEqual(before[0] & ~control_mask, model.words[0] & ~control_mask);
    try std.testing.expectEqual(before[1] & ~analog_mask, model.words[1] & ~analog_mask);
    var dropped = Model{ .drop = true };
    try std.testing.expect(!program(&dropped, selected));
}
