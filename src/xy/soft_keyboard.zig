//! On-screen keyboard for the xy workspace.
//!
//! The keyboard docks to the bottom of the logical viewport and
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
//! Rendering and hit testing share the same layout and state.

const std = @import("std");
pub const code_section = if (@import("builtin").os.tag == .freestanding) ".flash.xytext" else if (@import("builtin").object_format == .macho) "__TEXT,__text" else ".text";

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
    shift,
    symbols,
    left,
    right,
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
pub const label_shift: u8 = 1;
pub const label_symbols: u8 = 2;
pub const label_left: u8 = 3;
pub const label_right: u8 = 4;
pub const State = struct { symbols: bool = false, shift: bool = false };
pub const Orientation = enum { portrait, landscape };
pub const Geometry = struct {
    width: u32,
    height: u32,
    row_height: u32,
    pub fn keyboardHeight(self: Geometry) u32 {
        return rows * self.row_height;
    }
    pub fn top(self: Geometry) u32 {
        return self.height - self.keyboardHeight();
    }
};
pub fn geometry(orientation: Orientation) Geometry {
    return switch (orientation) {
        .landscape => .{ .width = 1280, .height = 720, .row_height = 72 },
        .portrait => .{ .width = 720, .height = 1280, .row_height = 80 },
    };
}

const row_letters = [3][]const u8{ "qwertyuiop", "asdfghjkl", "zxcvbnm" };

/// Every key, in paint order. Returns the slice of `buffer` that was used.
pub fn layout(buffer: []KeyRect) []KeyRect {
    return layoutState(buffer, .{});
}

pub fn layoutState(buffer: []KeyRect, state: State) []KeyRect {
    return layoutIn(buffer, state, .landscape);
}
pub fn layoutIn(buffer: []KeyRect, state: State, orientation: Orientation) []KeyRect {
    const g = geometry(orientation);
    var count: usize = 0;
    const push = struct {
        fn add(out: []KeyRect, n: *usize, rect: KeyRect) void {
            if (n.* >= out.len) return;
            out[n.*] = rect;
            n.* += 1;
        }
    }.add;
    const symbol_rows = [3][]const u8{ "1234567890", "-/:;()$&@\"", ".,?!'[]{}#" };
    const symbol_shift_rows = [3][]const u8{ "~`|^\\%+=_*", "<>\\\"'@#$&%", ".,?!:;{}[]" };
    const selected = if (state.symbols) (if (state.shift) symbol_shift_rows else symbol_rows) else row_letters;
    for (selected, 0..) |letters, row| {
        const y = g.top() + @as(u32, @intCast(row)) * g.row_height;
        // Half-key indent on the home row, like a physical keyboard.
        const indent: u32 = if (row == 1) g.width / 20 else 0;
        const usable = g.width - indent;
        const key_width = usable / @as(u32, @intCast(letters.len + (if (row == 2) @as(usize, 1) else 0)));
        for (letters, 0..) |raw_letter, i| {
            const letter = if (!state.symbols and state.shift) std.ascii.toUpper(raw_letter) else raw_letter;
            push(buffer, &count, .{
                .x = indent + @as(u32, @intCast(i)) * key_width,
                .y = y,
                .w = key_width,
                .h = g.row_height,
                .action = .{ .char = letter },
                .label = letter,
            });
        }
        if (row == 2) {
            push(buffer, &count, .{
                .x = indent + @as(u32, @intCast(letters.len)) * key_width,
                .y = y,
                .w = g.width - (indent + @as(u32, @intCast(letters.len)) * key_width),
                .h = g.row_height,
                .action = .backspace,
                .label = label_backspace,
            });
        }
    }
    // Shared geometry is used for painting and hit testing.
    const y = g.top() + 3 * g.row_height;
    const unit = g.width / 10;
    push(buffer, &count, .{ .x = 0, .y = y, .w = unit, .h = g.row_height, .action = .escape, .label = label_escape });
    push(buffer, &count, .{ .x = unit, .y = y, .w = unit, .h = g.row_height, .action = .shift, .label = label_shift });
    push(buffer, &count, .{ .x = unit * 2, .y = y, .w = unit, .h = g.row_height, .action = .symbols, .label = label_symbols });
    push(buffer, &count, .{ .x = unit * 3, .y = y, .w = unit * 3, .h = g.row_height, .action = .{ .char = ' ' }, .label = label_space });
    push(buffer, &count, .{ .x = unit * 6, .y = y, .w = unit, .h = g.row_height, .action = .left, .label = label_left });
    push(buffer, &count, .{ .x = unit * 7, .y = y, .w = unit, .h = g.row_height, .action = .right, .label = label_right });
    push(buffer, &count, .{ .x = unit * 8, .y = y, .w = unit, .h = g.row_height, .action = .enter, .label = label_enter });
    push(buffer, &count, .{ .x = unit * 9, .y = y, .w = unit, .h = g.row_height, .action = .dismiss, .label = label_dismiss });
    return buffer[0..count];
}

pub const max_keys = 40;

/// The action for a touch point, or null when the point is outside the
/// docked keyboard or lands on no key.
pub fn keyAt(x: u32, y: u32) ?Action {
    return keyAtState(x, y, .{});
}

pub fn keyAtState(x: u32, y: u32, state: State) ?Action {
    return keyAtIn(x, y, state, .landscape);
}
pub fn keyAtIn(x: u32, y: u32, state: State, orientation: Orientation) linksection(code_section) ?Action {
    const g = geometry(orientation);
    if (x >= g.width or y < g.top() or y >= g.height) return null;
    var rects: [max_keys]KeyRect = undefined;
    for (layoutIn(&rects, state, orientation)) |rect| {
        if (x >= rect.x and x < rect.x + rect.w and y >= rect.y and y < rect.y + rect.h) return rect.action;
    }
    return null;
}

/// Whether a point falls inside the docked keyboard area at all.
pub fn contains(x: u32, y: u32) bool {
    return containsIn(x, y, .landscape);
}
pub fn containsIn(x: u32, y: u32, orientation: Orientation) bool {
    const g = geometry(orientation);
    return x < g.width and y >= g.top() and y < g.height;
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
    return edgeGestureIn(start_x, start_y, end_x, end_y, .landscape);
}
pub fn edgeGestureIn(start_x: u32, start_y: u32, end_x: u32, end_y: u32, orientation: Orientation) Gesture {
    const g = geometry(orientation);
    if (start_x >= g.width or end_x >= g.width or start_y >= g.height or end_y >= g.height) return .none;
    if (start_y >= g.height - edge_band and start_y >= end_y + swipe_min) return .show;
    if (start_y >= g.top() and end_y >= start_y + swipe_min) return .hide;
    return .none;
}

/// A bus error or disabled probe is unknown, not evidence of absence.
pub const KeyboardProbe = enum { unknown, absent, present };
/// Require two matching scheduled observations. Unknown faults discard pending
/// changes but preserve the last confirmed state.
pub const PresenceTracker = struct {
    stable: KeyboardProbe = .unknown,
    pending: KeyboardProbe = .unknown,
    count: u8 = 0,
    pub fn observe(self: *PresenceTracker, observed: KeyboardProbe) linksection(code_section) void {
        if (observed == .unknown or observed == self.stable) {
            self.pending = .unknown;
            self.count = 0;
            return;
        }
        if (self.pending != observed) {
            self.pending = observed;
            self.count = 1;
            return;
        }
        self.count +|= 1;
        if (self.count >= 2) {
            self.stable = observed;
            self.pending = .unknown;
            self.count = 0;
        }
    }
};
pub fn probeFromResult(enabled: bool, ready: bool, report_status: u32, failed: bool) KeyboardProbe {
    if (!enabled or failed) return .unknown;
    if (ready) return .present;
    return if (report_status == 2) .absent else .unknown;
}
pub fn startupOrientation(probe: KeyboardProbe, force_portrait_fixture: bool) Orientation {
    if (force_portrait_fixture or probe == .absent) return .portrait;
    return .landscape;
}

/// Historical policy helper retained for consumers with a definitive probe.
pub fn defaultOrientation(physical_keyboard: bool) Orientation {
    return if (physical_keyboard) .landscape else .portrait;
}

test "layout covers the dock with letter rows and a bottom row" {
    var rects: [max_keys]KeyRect = undefined;
    const keys = layout(&rects);
    try std.testing.expectEqual(@as(usize, 10 + 9 + 7 + 1 + 8), keys.len);
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
    try std.testing.expectEqual(Action.enter, keyAt(space_width / 10 * 8 + 10, top + 3 * row_height + 10).?);
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

test "every printable ASCII character is reachable in the keyboard layouts" {
    var found: [128]bool = @splat(false);
    var rects: [max_keys]KeyRect = undefined;
    for ([_]State{ .{}, .{ .shift = true }, .{ .symbols = true }, .{ .symbols = true, .shift = true } }) |state| {
        for (layoutState(&rects, state)) |rect| {
            if (rect.action == .char) {
                found[rect.action.char] = true;
                try std.testing.expectEqual(rect.action, keyAtState(rect.x + rect.w / 2, rect.y + rect.h / 2, state).?);
            }
        }
    }
    for (32..127) |c| try std.testing.expect(found[c]);
}

test "portrait and landscape layouts stay on screen and match touch hit testing" {
    var rects: [max_keys]KeyRect = undefined;
    for ([_]Orientation{ .landscape, .portrait }) |orientation| {
        const g = geometry(orientation);
        for ([_]State{ .{}, .{ .shift = true }, .{ .symbols = true }, .{ .symbols = true, .shift = true } }) |state| {
            const keys = layoutIn(&rects, state, orientation);
            for (keys, 0..) |key, i| {
                try std.testing.expect(key.w >= 60 and key.h >= 72);
                try std.testing.expect(key.x + key.w <= g.width and key.y >= g.top() and key.y + key.h <= g.height);
                try std.testing.expectEqual(key.action, keyAtIn(key.x + key.w / 2, key.y + key.h / 2, state, orientation).?);
                for (keys[i + 1 ..]) |other| {
                    try std.testing.expect(key.x + key.w <= other.x or other.x + other.w <= key.x or key.y + key.h <= other.y or other.y + other.h <= key.y);
                }
            }
        }
        try std.testing.expectEqual(Gesture.show, edgeGestureIn(g.width / 2, g.height - 4, g.width / 2, g.height - 120, orientation));
        try std.testing.expectEqual(Gesture.hide, edgeGestureIn(g.width / 2, g.top() + 10, g.width / 2, g.top() + 100, orientation));
        try std.testing.expectEqual(Gesture.none, edgeGestureIn(g.width, g.height - 4, 0, g.height - 120, orientation));
    }
}

test "startup orientation requires confirmed absence and preserves fault fallback" {
    try std.testing.expectEqual(Orientation.portrait, startupOrientation(.absent, false));
    try std.testing.expectEqual(Orientation.landscape, startupOrientation(.present, false));
    try std.testing.expectEqual(Orientation.landscape, startupOrientation(.unknown, false));
    try std.testing.expectEqual(Orientation.portrait, startupOrientation(.unknown, true));
    try std.testing.expectEqual(KeyboardProbe.absent, probeFromResult(true, false, 2, false));
    try std.testing.expectEqual(KeyboardProbe.present, probeFromResult(true, true, 1, false));
    try std.testing.expectEqual(KeyboardProbe.unknown, probeFromResult(false, false, 2, false));
    try std.testing.expectEqual(KeyboardProbe.unknown, probeFromResult(true, false, 2, true));
    try std.testing.expectEqual(KeyboardProbe.unknown, probeFromResult(true, false, 0, false));
}

test "presence transitions require two matching observations and faults do not rotate" {
    var t = PresenceTracker{ .stable = .absent };
    t.observe(.present);
    try std.testing.expectEqual(KeyboardProbe.absent, t.stable);
    t.observe(.unknown);
    t.observe(.present);
    try std.testing.expectEqual(KeyboardProbe.absent, t.stable);
    t.observe(.present);
    try std.testing.expectEqual(KeyboardProbe.present, t.stable);
    t.observe(.absent);
    t.observe(.present);
    try std.testing.expectEqual(KeyboardProbe.present, t.stable);
    t.observe(.absent);
    t.observe(.absent);
    try std.testing.expectEqual(KeyboardProbe.absent, t.stable);
}
