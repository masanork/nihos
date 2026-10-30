//! Host-testable routing boundary for a diagnostic camera overlay and the
//! post-boot session. The native UI must call this after decoding input and
//! must force/present the previous view when `dismissed` is returned.
const std = @import("std");
const Session = @import("text_console").session;
const Overlay = @import("camera_preview").Overlay;

pub const Disposition = enum { forwarded, dismissed, suppressed };
pub const Result = struct { disposition: Disposition, command: ?Session.Command = null };

/// One CPU0 owner serializes overlay transitions and session input. Inputs
/// arriving during repaint are suppressed, so a second event from the same
/// batch cannot activate a launcher item or submit a partial shell command.
pub fn route(overlay: *Overlay, sequence: u32, session: *Session.Model, key: Session.input.Key, sink: anytype) Result {
    switch (overlay.state) {
        .idle => return .{ .disposition = .forwarded, .command = session.handle(key, sink) },
        .visible => {
            _ = overlay.dismiss(sequence);
            return .{ .disposition = .dismissed };
        },
        .repaint_pending, .recovery_pending, .failed => return .{ .disposition = .suppressed },
    }
}

const Sink = struct {
    count: usize = 0,
    pub fn write(self: *@This(), bytes: []const u8) void {
        self.count += bytes.len;
    }
};

test "serial Escape closes preview without opening shell; later Escape opens it" {
    var overlay: Overlay = .{};
    var model: Session.Model = .{};
    var sink: Sink = .{};
    var serial: Session.input.Serial = .{};
    overlay.shown();
    try std.testing.expect(serial.feed(0x1b, 0) == null);
    const key = serial.expire(30_000).?;
    try std.testing.expectEqual(Disposition.dismissed, route(&overlay, 7, &model, key, &sink).disposition);
    try std.testing.expectEqual(Session.View.launcher, model.view);
    try std.testing.expectEqual(@as(u32, 0), model.revision);
    try std.testing.expectEqual(Disposition.suppressed, route(&overlay, 8, &model, .enter, &sink).disposition);
    try std.testing.expectEqual(@as(u32, 7), overlay.repainted().?.dismissal);
    try std.testing.expectEqual(Disposition.forwarded, route(&overlay, 9, &model, .escape, &sink).disposition);
    try std.testing.expectEqual(Session.View.shell, model.view);
}

test "HID dismissal preserves partially typed shell input until repaint" {
    var overlay: Overlay = .{};
    var model: Session.Model = .{};
    var sink: Sink = .{};
    var hid: Session.input.Hid = .{};
    _ = model.handle(.escape, &sink);
    for ("exit") |c| _ = model.handle(.{ .text = c }, &sink);
    const revision = model.revision;
    const written = sink.count;
    overlay.shown();
    try std.testing.expectEqual(Disposition.dismissed, route(&overlay, 11, &model, hid.feed(0, 0x29).?, &sink).disposition);
    try std.testing.expectEqual(Disposition.suppressed, route(&overlay, 12, &model, hid.feed(0, 0x28).?, &sink).disposition);
    try std.testing.expectEqual(revision, model.revision);
    try std.testing.expectEqual(written, sink.count);
    try std.testing.expectEqualStrings("exit", model.line[0..model.length]);
    _ = overlay.repainted();
    try std.testing.expectEqual(Disposition.forwarded, route(&overlay, 13, &model, .enter, &sink).disposition);
    try std.testing.expectEqual(Session.View.launcher, model.view);
}

test "serial arrows are decoded before dismissal and pending faults suppress input" {
    var overlay: Overlay = .{};
    var model: Session.Model = .{};
    var sink: Sink = .{};
    var serial: Session.input.Serial = .{};
    overlay.shown();
    for ("\x1b[") |c| try std.testing.expect(serial.feed(c, 0) == null);
    const down = serial.feed('B', 1).?;
    try std.testing.expectEqual(Disposition.dismissed, route(&overlay, 1, &model, down, &sink).disposition);
    try std.testing.expectEqual(@as(usize, 0), model.selected);
    _ = overlay.repainted();
    overlay.failed();
    try std.testing.expectEqual(Disposition.suppressed, route(&overlay, 2, &model, .enter, &sink).disposition);
    overlay.abandon();
    try std.testing.expectEqual(Disposition.suppressed, route(&overlay, 3, &model, .escape, &sink).disposition);
    try std.testing.expectEqual(@as(u32, 0), model.revision);
}

test "CRLF dismissal does not submit a partially typed command" {
    var overlay: Overlay = .{};
    var model: Session.Model = .{};
    var sink: Sink = .{};
    var serial: Session.input.Serial = .{};
    _ = model.handle(.escape, &sink);
    for ("exit") |c| _ = model.handle(.{ .text = c }, &sink);
    overlay.shown();
    try std.testing.expectEqual(Disposition.dismissed, route(&overlay, 1, &model, serial.feed('\r', 0).?, &sink).disposition);
    _ = overlay.repainted();
    try std.testing.expect(serial.feed('\n', 1) == null);
    try std.testing.expectEqual(Session.View.shell, model.view);
    try std.testing.expectEqualStrings("exit", model.line[0..model.length]);
}
