//! Shared, bounded live-definition lifecycle. Persistence belongs to the host.
//! Prepare is side-effect-free; activation is infallible after durable commit.
const std = @import("std");
pub const scheme = @import("scheme_runtime.zig");
pub const default_source = @embedFile("bootstrap.scm");
pub const source_limit = 4096;

const DefinitionHost = struct {
    pub fn schemeCall(_: *@This(), _: scheme.EditorOp, _: []const u8, _: i32) scheme.Error!void {
        return error.EditorFailure;
    }
};

pub fn Session(comptime Workspace: type) type {
    return struct {
        const Self = @This();
        active: scheme.Runtime,
        candidate: scheme.Runtime,
        backup_doc: Workspace.DocType = .{},
        prepared: bool = false,

        pub fn init(self: *Self) void {
            self.active.initInPlace();
            self.prepared = false;
        }
        pub fn prepare(self: *Self, source: []const u8, output: []u8) scheme.Error![]const u8 {
            self.prepared = false;
            self.candidate.initInPlace();
            var host = DefinitionHost{};
            const result = try self.candidate.evaluate(source, &host, output);
            self.prepared = true;
            return result;
        }
        pub fn activate(self: *Self) bool {
            if (!self.prepared) return false;
            self.active = self.candidate;
            self.prepared = false;
            return true;
        }
        pub fn discard(self: *Self) void {
            self.prepared = false;
        }
        const Adapter = struct {
            ws: *Workspace,
            pub fn schemeCall(self: *@This(), op: scheme.EditorOp, text: []const u8, number: i32) scheme.Error!void {
                switch (op) {
                    .insert => self.ws.doc.insertUtf8(text) catch return error.EditorFailure,
                    .move => {
                        // Avoid signed-negation overflow in older Document revisions.
                        const bound: i32 = @intCast(self.ws.doc.len);
                        _ = self.ws.doc.moveGraphemes(std.math.clamp(number, -bound, bound)) catch return error.EditorFailure;
                    },
                    .undo => {
                        _ = self.ws.doc.undo() catch return error.EditorFailure;
                    },
                    // System snapshots and explicit undo discard need a separate host contract.
                    else => return error.EditorFailure,
                }
            }
        };
        pub fn run(self: *Self, ws: *Workspace, source: []const u8, named: bool, output: []u8) scheme.Error![]const u8 {
            return self.transaction(ws, source, if (named) .command else .expression, 0, output);
        }
        pub fn runApp(self: *Self, ws: *Workspace, state: *scheme.plot_config.State, source: []const u8, output: []u8) scheme.Error![]const u8 {
            if (self.prepared) return error.Busy;
            self.active.app = state.*;
            const result = try self.run(ws, source, false, output);
            state.* = self.active.app;
            return result;
        }
        pub fn frame(self: *Self, ws: *Workspace, state: *scheme.plot_config.State) scheme.Error!void {
            if (self.prepared) return error.Busy;
            self.active.app = state.*;
            var unused: [0]u8 = .{};
            _ = try self.transaction(ws, "", .frame, state.ticks, &unused);
            state.* = self.active.app;
        }
        fn frameResult(self: *Self, ticks: i32, adapter: *Adapter, output: []u8) scheme.Error![]const u8 {
            try self.active.runFrame(ticks, adapter);
            return output[0..0];
        }
        const Mode = enum { expression, command, frame };
        fn transaction(self: *Self, ws: *Workspace, source: []const u8, mode: Mode, ticks: i32, output: []u8) scheme.Error![]const u8 {
            // A pending commit must not be invalidated by interactive evaluation.
            if (self.prepared) return error.Busy;
            if (comptime @hasField(Workspace, "appearance")) {
                self.active.view = .{ .style = ws.style, .appearance = ws.appearance };
            }
            self.candidate = self.active;
            self.backup_doc = ws.doc;
            const old_dirty = ws.layout_dirty;
            _ = ws.doc.beginUndoGroup();
            var adapter = Adapter{ .ws = ws };
            const result = (switch (mode) {
                .expression => self.active.evaluate(source, &adapter, output),
                .command => self.active.runCommand(source, &adapter, output),
                .frame => self.frameResult(ticks, &adapter, output),
            }) catch |err| {
                self.active = self.candidate;
                ws.doc = self.backup_doc;
                ws.layout_dirty = old_dirty;
                return err;
            };
            if (comptime @hasField(Workspace, "appearance")) {
                ws.style = self.active.view.style;
                ws.appearance = self.active.view.appearance;
            }
            ws.doc.endUndoGroup();
            ws.layout_dirty = mode != .frame or old_dirty or ws.doc.revision != self.backup_doc.revision or !std.meta.eql(self.active.view, self.candidate.view);
            return result;
        }
    };
}

const Document = @import("document.zig");
const TestWorkspace = struct {
    pub const DocType = Document.Document(4096, 32, 1024, 8, 64);
    doc: DocType = .{},
    layout_dirty: bool = false,
};
test "prepare rejects effects, swaps commands without stale closures, and removes deleted definitions" {
    // SAFETY: init initializes the runtime before any operation.
    var live: Session(TestWorkspace) = undefined;
    live.init();
    var ws = TestWorkspace{};
    var out: [256]u8 = undefined;
    _ = try live.prepare(default_source, &out);
    try std.testing.expect(live.activate());
    _ = try live.run(&ws, "stamp", true, &out);
    try std.testing.expectEqualStrings("Hello from Scheme!\n", ws.doc.slice());
    _ = try live.prepare("(define (stamp) (buffer/insert! \"new\"))", &out);
    try std.testing.expectError(error.Busy, live.run(&ws, "stamp", true, &out));
    try std.testing.expect(live.activate());
    _ = try live.run(&ws, "stamp", true, &out);
    try std.testing.expectEqualStrings("Hello from Scheme!\nnew", ws.doc.slice());
    try std.testing.expectError(error.EditorFailure, live.prepare("(buffer/insert! \"bad\")", &out));
    try std.testing.expect(!live.activate());
    _ = try live.run(&ws, "stamp", true, &out);
    _ = try live.prepare("(define value 7)", &out);
    try std.testing.expect(live.activate());
    try std.testing.expectError(error.UnknownCommand, live.run(&ws, "stamp", true, &out));
}
test "failed evaluation restores definitions and document; repeated loads and extreme movement recover" {
    // SAFETY: init initializes the runtime before any operation.
    var live: Session(TestWorkspace) = undefined;
    live.init();
    var ws = TestWorkspace{};
    var out: [256]u8 = undefined;
    _ = try live.run(&ws, "(define value 7)", false, &out);
    try std.testing.expectError(error.Unbound, live.run(&ws, "(set! value 9) (buffer/insert! \"bad\") missing", false, &out));
    try std.testing.expectEqualStrings("", ws.doc.slice());
    try std.testing.expectEqualStrings("7", try live.run(&ws, "value", false, &out));
    _ = try live.run(&ws, "(buffer/insert! \"葛󠄀が\") (buffer/move-graphemes! -2147483648)", false, &out);
    try std.testing.expectEqual(@as(u32, 0), ws.doc.cursor);
    for (0..100) |_| {
        _ = try live.prepare(default_source, &out);
        try std.testing.expect(live.activate());
    }
}

test "frame failure rolls back VM editor and plot; next editor evaluation recovers" {
    // SAFETY: initialized before use.
    var live: Session(TestWorkspace) = undefined;
    live.init();
    var ws = TestWorkspace{};
    var state = scheme.plot_config.State{ .enabled = true };
    var out: [256]u8 = undefined;
    _ = try live.runApp(&ws, &state, "(define keep 7) (app/on-frame! (lambda (t) (set! keep 9) (buffer/insert! \"bad\") (plot/set! #:phase 42) missing))", &out);
    try std.testing.expectError(error.Unbound, live.frame(&ws, &state));
    try std.testing.expectEqualStrings("", ws.doc.slice());
    try std.testing.expectEqual(@as(u8, 0), state.plot.phase);
    live.active.clearFrame();
    try std.testing.expectEqualStrings("7", try live.runApp(&ws, &state, "keep", &out));
    _ = try live.runApp(&ws, &state, "(buffer/insert! \"good\")", &out);
    try std.testing.expectEqualStrings("good", ws.doc.slice());
}

test "frame budget abort and heap pressure recover transactionally without resetting definitions" {
    // SAFETY: initialized before use.
    var live: Session(TestWorkspace) = undefined;
    live.init();
    var ws = TestWorkspace{};
    var state = scheme.plot_config.State{ .enabled = true };
    var out: [256]u8 = undefined;
    const work = "(define (work) " ++ repeated("(if #t #t #t) ", 12) ++ ")";
    _ = try live.runApp(&ws, &state, work ++ "(app/on-frame! (lambda (t) " ++ repeated("(work) ", 6) ++ "))", &out);
    try std.testing.expectError(error.Budget, live.frame(&ws, &state));
    live.active.clearFrame();
    _ = try live.runApp(&ws, &state, "(app/on-frame! (lambda (t) (work)))", &out);
    for (0..600) |_| try live.frame(&ws, &state);
    _ = try live.runApp(&ws, &state, "(app/on-frame! (lambda (t) (define (loop) (loop)) (loop)))", &out);
    try std.testing.expectError(error.Depth, live.frame(&ws, &state));
    live.active.clearFrame();
    try std.testing.expectEqualStrings("42", try live.runApp(&ws, &state, "(+ 20 22)", &out));
    _ = try live.runApp(&ws, &state, "(define saved '()) (app/on-frame! (lambda (t) (set! saved (cons t saved))))", &out);
    var full = false;
    for (0..256) |_| live.frame(&ws, &state) catch |err| {
        try std.testing.expectEqual(error.HeapFull, err);
        full = true;
        break;
    };
    try std.testing.expect(full);
    live.active.clearFrame();
    // The frame reserve leaves space to parse and evaluate a recovery form.
    _ = try live.runApp(&ws, &state, "(set! saved '())", &out);
    try std.testing.expectEqualStrings("42", try live.runApp(&ws, &state, "(+ 20 22)", &out));
}

fn repeated(comptime bytes: []const u8, comptime count: usize) [bytes.len * count]u8 {
    var result: [bytes.len * count]u8 = undefined;
    for (0..count) |index| @memcpy(result[index * bytes.len ..][0..bytes.len], bytes);
    return result;
}
