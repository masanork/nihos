//! One presentation contract for Scheme, RGB565 and desktop RGBA renderers.
//! Defaults belong here; renderers consume values, never select their own theme.
const std = @import("std");
pub const Style = extern struct {
    style_id: u8 = 0, // 0: mincho, 1: gothic
    body_px: u8 = 24,
    ruby_px: u8 = 12,
    axis: u8 = 0, // 0: horizontal, 1: vertical
    line_gap_px: u8 = 12,
    ruby_gap_px: u8 = 2,
    margin_x_px: u16 = 24,
    margin_y_px: u16 = 24,
    viewport_width_px: u16 = 1280,
    viewport_height_px: u16 = 720,
};

pub const section = if (@import("builtin").os.tag == .freestanding) ".flash.xytext" else if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";
pub const data_section = if (@import("builtin").os.tag == .freestanding) ".flash.xyrodata" else if (@import("builtin").object_format == .macho) "__TEXT,__const" else ".rodata";
const names linksection(data_section) = "size\x00ruby-size\x00line-gap\x00ruby-gap\x00margin-x\x00margin-y\x00background\x00foreground\x00ruby-color\x00cursor-color\x00status-background\x00status-foreground\x00cursor-width\x00status-padding\x00".*;
const word_background linksection(data_section) = "background".*;
const word_bunsen_gothic linksection(data_section) = "bunsen-gothic".*;
const word_bunsen_mincho linksection(data_section) = "bunsen-mincho".*;
const word_cursor_color linksection(data_section) = "cursor-color".*;
const word_cursor_width linksection(data_section) = "cursor-width".*;
const word_dark linksection(data_section) = "dark".*;
const word_direction linksection(data_section) = "direction".*;
const word_font linksection(data_section) = "font".*;
const word_foreground linksection(data_section) = "foreground".*;
const word_gothic linksection(data_section) = "gothic".*;
const word_horizontal linksection(data_section) = "horizontal".*;
const word_light linksection(data_section) = "light".*;
const word_line_gap linksection(data_section) = "line-gap".*;
const word_linear_blend linksection(data_section) = "linear-blend".*;
const word_margin_x linksection(data_section) = "margin-x".*;
const word_margin_y linksection(data_section) = "margin-y".*;
const word_mincho linksection(data_section) = "mincho".*;
const word_ruby_color linksection(data_section) = "ruby-color".*;
const word_ruby_gap linksection(data_section) = "ruby-gap".*;
const word_ruby_size linksection(data_section) = "ruby-size".*;
const word_size linksection(data_section) = "size".*;
const word_status_background linksection(data_section) = "status-background".*;
const word_status_foreground linksection(data_section) = "status-foreground".*;
const word_status_padding linksection(data_section) = "status-padding".*;
const word_theme linksection(data_section) = "theme".*;
const word_vertical linksection(data_section) = "vertical".*;
pub const Error = error{ UnknownOption, InvalidValue };
pub const Value = union(enum) { number: i32, symbol: []const u8, boolean: bool };
pub const Appearance = struct {
    background: u32 = 0xfaf6ee,
    foreground: u32 = 0x1c1c1e,
    ruby_color: u32 = 0x5c4033,
    cursor_color: u32 = 0xcc3322,
    status_background: u32 = 0xeae4d6,
    status_foreground: u32 = 0x283848,
    cursor_width: u8 = 2,
    status_padding: u8 = 4,
    linear_blend: bool = false,
};
pub const Config = struct {
    style: Style = .{},
    appearance: Appearance = .{},

    pub fn set(self: *Config, key: []const u8, value: Value) linksection(section) Error!void {
        // Work on a copy even for options which derive other values.
        var next = self.*;
        if (eq(key, &word_font)) {
            const name = try symbol(value);
            next.style.style_id = if (eq(name, &word_mincho) or eq(name, &word_bunsen_mincho)) 0 else if (eq(name, &word_gothic) or eq(name, &word_bunsen_gothic)) 1 else return error.InvalidValue;
        } else if (eq(key, &word_direction)) {
            const name = try symbol(value);
            next.style.axis = if (eq(name, &word_horizontal)) 0 else if (eq(name, &word_vertical)) 1 else return error.InvalidValue;
        } else if (eq(key, &word_theme)) {
            const name = try symbol(value);
            if (eq(name, &word_light)) next.appearance = .{} else if (eq(name, &word_dark)) next.appearance = .{
                .background = 0x121418,
                .foreground = 0xe6eaf0,
                .ruby_color = 0x8ab4f8,
                .cursor_color = 0xffa657,
                .status_background = 0x1e222a,
                .status_foreground = 0xa8dab5,
            } else return error.InvalidValue;
        } else if (eq(key, &word_size)) {
            next.style.body_px = @intCast(try number(value, 8, 96));
            next.style.ruby_px = @max(6, next.style.body_px / 2);
        } else if (eq(key, &word_ruby_size)) {
            next.style.ruby_px = @intCast(try number(value, 6, 48));
        } else if (eq(key, &word_line_gap)) {
            next.style.line_gap_px = @intCast(try number(value, 0, 64));
        } else if (eq(key, &word_ruby_gap)) {
            next.style.ruby_gap_px = @intCast(try number(value, 0, 64));
        } else if (eq(key, &word_margin_x)) {
            next.style.margin_x_px = @intCast(try number(value, 0, 512));
        } else if (eq(key, &word_margin_y)) {
            next.style.margin_y_px = @intCast(try number(value, 0, 512));
        } else if (eq(key, &word_background)) {
            next.appearance.background = @intCast(try number(value, 0, 0xffffff));
        } else if (eq(key, &word_foreground)) {
            next.appearance.foreground = @intCast(try number(value, 0, 0xffffff));
        } else if (eq(key, &word_ruby_color)) {
            next.appearance.ruby_color = @intCast(try number(value, 0, 0xffffff));
        } else if (eq(key, &word_cursor_color)) {
            next.appearance.cursor_color = @intCast(try number(value, 0, 0xffffff));
        } else if (eq(key, &word_status_background)) {
            next.appearance.status_background = @intCast(try number(value, 0, 0xffffff));
        } else if (eq(key, &word_status_foreground)) {
            next.appearance.status_foreground = @intCast(try number(value, 0, 0xffffff));
        } else if (eq(key, &word_cursor_width)) {
            next.appearance.cursor_width = @intCast(try number(value, 1, 8));
        } else if (eq(key, &word_status_padding)) {
            next.appearance.status_padding = @intCast(try number(value, 0, 32));
        } else if (eq(key, &word_linear_blend)) {
            next.appearance.linear_blend = switch (value) {
                .boolean => |b| b,
                else => return error.InvalidValue,
            };
        } else return error.UnknownOption;
        self.* = next;
    }
    pub fn validate(self: Config) linksection(section) Error!void {
        const bar = @as(u32, self.style.body_px) + 2 * @as(u32, self.appearance.status_padding);
        if (2 * @as(u32, self.style.margin_x_px) + self.style.body_px >= self.style.viewport_width_px or
            2 * @as(u32, self.style.margin_y_px) + self.style.body_px + bar >= self.style.viewport_height_px) return error.InvalidValue;
    }
    pub fn get(self: Config, key: []const u8) linksection(section) Error!Value {
        const values = [_]i32{ self.style.body_px, self.style.ruby_px, self.style.line_gap_px, self.style.ruby_gap_px, self.style.margin_x_px, self.style.margin_y_px, @intCast(self.appearance.background), @intCast(self.appearance.foreground), @intCast(self.appearance.ruby_color), @intCast(self.appearance.cursor_color), @intCast(self.appearance.status_background), @intCast(self.appearance.status_foreground), self.appearance.cursor_width, self.appearance.status_padding };
        var start: usize = 0;
        for (values) |n| {
            const end = start + (std.mem.indexOfScalar(u8, names[start..], 0) orelse return error.UnknownOption);
            if (eq(key, names[start..end])) return .{ .number = n };
            start = end + 1;
        }
        if (eq(key, &word_font)) return .{ .symbol = if (self.style.style_id == 0) &word_bunsen_mincho else &word_bunsen_gothic };
        if (eq(key, &word_direction)) return .{ .symbol = if (self.style.axis == 0) &word_horizontal else &word_vertical };
        if (eq(key, &word_linear_blend)) return .{ .boolean = self.appearance.linear_blend };
        return error.UnknownOption;
    }
};
inline fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
inline fn symbol(v: Value) Error![]const u8 {
    return switch (v) {
        .symbol => |s| s,
        else => error.InvalidValue,
    };
}
inline fn number(v: Value, min: i32, max: i32) Error!i32 {
    const n = switch (v) {
        .number => |n| n,
        else => return error.InvalidValue,
    };
    return if (n >= min and n <= max) n else error.InvalidValue;
}

/// UTF-8 ranges of code in an attributed reading page.
pub const CodeSpan = extern struct { start: u32, end: u32 };
