//! On-screen keyboard for the xy workspace.
//!
//! The workspace has one logical touch space of 1280x720. When no physical
//! keyboard is present, this keyboard docks to the bottom of that space and
//! turns touches into the same key events a HID keyboard produces, so the
//! editor, minibuffer and the romaji IME core cannot tell the difference.
//!
//! Policy, as agreed for the workspace:
//! - Show the keyboard by default only while no physical keyboard is
//!   present, a text input context is active, and the user has not
//!   dismissed it for this context.
//! - The default orientation follows the physical keyboard: portrait
//!   without one, landscape with one. This module only records the
//!   decision; renderers may override it per screen.
//!
//! Rendering is deliberately left to callers: `layout` exposes every key
//! rectangle and label so a renderer can paint the keyboard without
//! duplicating geometry.

const std = @import("std");

/// Logical workspace size this keyboard docks into.
pub const space_width: u32 = 1280;
pub const space_height: u32 = 720;
/// Docked keyboard geometry: four rows of 72 px at the bottom.
pub const rows: u32 = 4;
pub const row_height: u32 = 72;
pub const height: u32 = rows * row_height;
pub const top: u32 = space_height - height;

pub const Action = union(enum) {
    /// One ASCII byte, exactly as a HID key press would deliver.
    char: u8,
    enter,
    backspace,
    escape,
    /// Hide the keyboard until the input context changes.
    dismiss,
};

pub const KeyRect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
    action: Action,
    /// Glyph a renderer should draw: the byte itself for character keys,
    /// or one of the symbolic labels below.
    label: u8,
};

pub const label_backspace: u8 = 0x08;
pub const label_enter: u8 = 0x0d;
pub const label_escape: u8 = 0x1b;
pub const label_dismiss: u8 = 0x19; // Down-arrow: lower the keyboard.
pub const label_space: u8 = ' ';

const row_letters = [3][]const u8{ "qwertyuiop", "asdfghjkl", "zxcvbnm" };

/// Every key, in paint order. Returns the slice of `buffer` that was used.
pub fn layout(buffer: []KeyRect) []KeyRect {
    var count: usize = 0;
    const push = struct {
        fn add(out: []KeyRect, n: *usize, rect: KeyRect) void {
            if (n.* >= out.len) return;
            out[n.*] = rect;
            n.* += 1;
        }
    }.add;
    for (row_letters, 0..) |letters, row| {
        const y = top + @as(u32, @intCast(row)) * row_height;
        // Half-key indent on the home row, like a physical keyboard.
        const indent: u32 = if (row == 1) space_width / 20 else 0;
        const usable = space_width - indent;
        const key_width = usable / @as(u32, @intCast(letters.len + (if (row == 2) @as(usize, 1) else 0)));
        for (letters, 0..) |letter, i| {
            push(buffer, &count, .{
                .x = indent + @as(u32, @intCast(i)) * key_width,
                .y = y,
                .w = key_width,
                .h = row_height,
                .action = .{ .char = letter },
                .label = letter,
            });
        }
        if (row == 2) {
            push(buffer, &count, .{
                .x = indent + @as(u32, @intCast(letters.len)) * key_width,
                .y = y,
                .w = space_width - (indent + @as(u32, @intCast(letters.len)) * key_width),
                .h = row_height,
                .action = .backspace,
                .label = label_backspace,
            });
        }
    }
    // Bottom row: escape, space, enter, dismiss.
    const y = top + 3 * row_height;
    const unit = space_width / 8;
    push(buffer, &count, .{ .x = 0, .y = y, .w = unit, .h = row_height, .action = .escape, .label = label_escape });
    push(buffer, &count, .{ .x = unit, .y = y, .w = unit * 5, .h = row_height, .action = .{ .char = ' ' }, .label = label_space });
    push(buffer, &count, .{ .x = unit * 6, .y = y, .w = unit, .h = row_height, .action = .enter, .label = label_enter });
    push(buffer, &count, .{ .x = unit * 7, .y = y, .w = unit, .h = row_height, .action = .dismiss, .label = label_dismiss });
    return buffer[0..count];
}

pub const max_keys = 40;

/// The action for a touch point, or null when the point is outside the
/// docked keyboard or lands on no key.
pub fn keyAt(x: u32, y: u32) ?Action {
    if (x >= space_width or y < top or y >= space_height) return null;
    var rects: [max_keys]KeyRect = undefined;
    for (layout(&rects)) |rect| {
        if (x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h) return rect.action;
    }
    return null;
}

/// Whether a point falls inside the docked keyboard area at all.
pub fn contains(x: u32, y: u32) bool {
    return x < space_width and y >= top and y < space_height;
}

/// Visibility policy: physical keyboards win, dismissal sticks for the
/// current context, and non-input screens never grow a keyboard.
pub fn visible(physical_keyboard: bool, input_context: bool, dismissed: bool) bool {
    return !physical_keyboard and input_context and !dismissed;
}

/// Bottom-edge band a show swipe must start in, and the minimum travel
/// for a flick to count as a gesture instead of a tap.
pub const edge_band: u32 = 24;
pub const swipe_min: u32 = 48;

pub const Gesture = enum { none, show, hide };

/// Recognizes the manual override gestures from a touch's start and end
/// points: flick up from the bottom edge to summon the keyboard, flick
/// down across the keyboard to dismiss it. Anything else is a tap.
pub fn edgeGesture(start_x: u32, start_y: u32, end_x: u32, end_y: u32) Gesture {
    _ = start_x;
    _ = end_x;
    if (start_y >= space_height - edge_band and start_y >= end_y + swipe_min) return .show;
    if (start_y >= top and end_y >= start_y + swipe_min) return .hide;
    return .none;
}

pub const Orientation = enum { portrait, landscape };

/// Default orientation for a session: the keyboard accessory holds the
/// device horizontally, so its presence makes landscape the basis.
pub fn defaultOrientation(physical_keyboard: bool) Orientation {
    return if (physical_keyboard) .landscape else .portrait;
}

test "layout covers the dock with letter rows and a bottom row" {
    var rects: [max_keys]KeyRect = undefined;
    const keys = layout(&rects);
    try std.testing.expectEqual(@as(usize, 10 + 9 + 7 + 1 + 4), keys.len);
    try std.testing.expectEqual(@as(u8, 'q'), keys[0].label);
    try std.testing.expectEqual(@as(u32, top), keys[0].y);
    // Every key stays inside the docked area.
    for (keys) |rect| {
        try std.testing.expect(rect.y >= top and rect.y + rect.h <= space_height);
        try std.testing.expect(rect.x + rect.w <= space_width);
    }
}

test "keyAt maps touches to the same bytes a HID keyboard sends" {
    try std.testing.expectEqual(Action{ .char = 'q' }, keyAt(10, top + 10).?);
    try std.testing.expectEqual(Action{ .char = ' ' }, keyAt(space_width / 2, top + 3 * row_height + 10).?);
    try std.testing.expectEqual(Action.backspace, keyAt(space_width - 10, top + 2 * row_height + 10).?);
    try std.testing.expectEqual(Action.enter, keyAt(space_width / 8 * 6 + 10, top + 3 * row_height + 10).?);
    try std.testing.expectEqual(Action.dismiss, keyAt(space_width - 10, top + 3 * row_height + 10).?);
    try std.testing.expect(keyAt(10, top - 1) == null);
    try std.testing.expect(keyAt(space_width, top + 10) == null);
    try std.testing.expect(contains(0, top));
    try std.testing.expect(!contains(0, top - 1));
}

test "edge gestures summon and dismiss, taps do not" {
    try std.testing.expectEqual(Gesture.show, edgeGesture(640, space_height - 4, 640, space_height - 120));
    try std.testing.expectEqual(Gesture.hide, edgeGesture(640, top + 20, 640, top + 140));
    try std.testing.expectEqual(Gesture.none, edgeGesture(640, space_height - 4, 640, space_height - 20));
    try std.testing.expectEqual(Gesture.none, edgeGesture(640, 300, 640, 420));
    try std.testing.expectEqual(Gesture.none, edgeGesture(640, top + 20, 640, top + 30));
}

test "policy: show only without a physical keyboard, in context, undismissed" {
    try std.testing.expect(visible(false, true, false));
    try std.testing.expect(!visible(true, true, false));
    try std.testing.expect(!visible(false, false, false));
    try std.testing.expect(!visible(false, true, true));
    try std.testing.expectEqual(Orientation.portrait, defaultOrientation(false));
    try std.testing.expectEqual(Orientation.landscape, defaultOrientation(true));
}
